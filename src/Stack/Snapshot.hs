{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE EmptyDataDecls      #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE ViewPatterns        #-}

-- | Reading in @SnapshotDef@s and converting them into
-- @LoadedSnapshot@s.
module Stack.Snapshot
  ( loadResolver
  , loadSnapshot
  ) where

import           Control.Applicative
import           Control.Monad (forM, unless, void)
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger
import           Control.Monad.Reader (MonadReader)
import           Control.Monad.State.Strict      (get, put, StateT, execStateT)
import           Crypto.Hash (hash, SHA256(..), Digest)
import           Crypto.Hash.Conduit (hashFile)
import           Data.Aeson (withObject, (.!=), (.:), (.:?), Value (Object))
import           Data.Aeson.Extended (WithJSONWarnings(..), logJSONWarnings, (..!=), (..:?), jsonSubWarningsT, withObjectWarnings, (..:))
import           Data.Aeson.Types (Parser, parseEither)
import           Data.Store.VersionTagged
import qualified Data.ByteArray as Mem (convert)
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Base64.URL as B64URL
import qualified Data.ByteString.Char8 as S8
import           Data.Conduit ((.|))
import qualified Data.Conduit.List as CL
import qualified Data.HashMap.Strict as HashMap
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (fromMaybe)
import           Data.Monoid
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding (encodeUtf8)
import           Data.Typeable (Typeable)
import           Data.Yaml (decodeFileEither, ParseException (AesonException))
import           Distribution.InstalledPackageInfo (PError)
import           Distribution.PackageDescription (GenericPackageDescription)
import qualified Distribution.PackageDescription as C
import           Distribution.System (Platform)
import qualified Distribution.Version as C
import           Network.HTTP.Client (Request)
import           Network.HTTP.Download
import           Path
import           Path.IO
import           Prelude -- Fix AMP warning
import           Stack.Constants
import           Stack.Fetch
import           Stack.Package
import           Stack.PackageDump
import           Stack.PackageLocation
import           Stack.Types.BuildPlan
import           Stack.Types.FlagName
import           Stack.Types.GhcPkgId
import           Stack.Types.PackageIdentifier
import           Stack.Types.PackageName
import           Stack.Types.Version
import           Stack.Types.VersionIntervals
import           Stack.Types.Config
import           Stack.Types.Urls
import           Stack.Types.Compiler
import           Stack.Types.Resolver
import           Stack.Types.StackT
import           System.FilePath (takeDirectory)

data SnapshotException
  = InvalidCabalFileInSnapshot !PackageLocation !PError !ByteString
  | PackageDefinedTwice !PackageName !PackageLocation !PackageLocation
  | UnmetDeps !(Map PackageName (Map PackageName (VersionIntervals, Maybe Version)))
  deriving (Show, Typeable) -- FIXME custom Show instance
instance Exception SnapshotException

-- | Convert a 'Resolver' into a 'SnapshotDef'
loadResolver
  :: forall env m.
     (StackMiniM env m, HasConfig env)
  => Resolver
  -> m SnapshotDef
loadResolver (ResolverSnapshot name) = do
    stackage <- view stackRootL
    file' <- parseRelFile $ T.unpack file
    let fp = buildPlanDir stackage </> file'
        tryDecode = liftIO $ do
          evalue <- decodeFileEither $ toFilePath fp
          return $
            case evalue of
              Left e -> Left e
              Right value ->
                case parseEither parseStackageSnapshot value of
                  Left s -> Left $ AesonException s
                  Right x -> Right x
    $logDebug $ "Decoding build plan from: " <> T.pack (toFilePath fp)
    eres <- tryDecode
    case eres of
        Right sd -> return sd
        Left e -> do
            $logDebug $ "Decoding Stackage snapshot definition from file failed: " <> T.pack (show e)
            ensureDir (parent fp)
            url <- buildBuildPlanUrl name file
            req <- parseRequest $ T.unpack url
            $logSticky $ "Downloading " <> renderSnapName name <> " build plan ..."
            $logDebug $ "Downloading build plan from: " <> url
            _ <- redownload req fp
            $logStickyDone $ "Downloaded " <> renderSnapName name <> " build plan."
            tryDecode >>= either throwM return

  where
    file = renderSnapName name <> ".yaml"

    buildBuildPlanUrl :: (MonadReader env m, HasConfig env) => SnapName -> Text -> m Text
    buildBuildPlanUrl snapName file' = do
        urls <- view $ configL.to configUrls
        return $
            case snapName of
                LTS _ _ -> urlsLtsBuildPlans urls <> "/" <> file'
                Nightly _ -> urlsNightlyBuildPlans urls <> "/" <> file'

    parseStackageSnapshot = withObject "StackageSnapshotDef" $ \o -> do
        Object si <- o .: "system-info"
        ghcVersion <- si .:? "ghc-version"
        compilerVersion <- si .:? "compiler-version"
        compilerVersion' <-
            case (ghcVersion, compilerVersion) of
                (Just _, Just _) -> fail "can't have both compiler-version and ghc-version fields"
                (Just ghc, _) -> return (GhcVersion ghc)
                (_, Just compiler) -> return compiler
                _ -> fail "expected field \"ghc-version\" or \"compiler-version\" not present"
        let sdParent = Left compilerVersion'

        packages <- o .: "packages"
        (Endo mkLocs, sdFlags, sdHide) <- fmap mconcat $ mapM (uncurry goPkg) $ Map.toList packages
        let sdLocations = mkLocs []

        let sdGhcOptions = Map.empty -- Stackage snapshots do not allow setting GHC options

        -- Not dropping any packages in a Stackage snapshot
        let sdDropPackages = Set.empty

        let sdResolver = ResolverSnapshot name

        return SnapshotDef {..}
      where
        goPkg name' = withObject "StackagePackageDef" $ \o -> do
            version <- o .: "version"
            mcabalFileInfo <- o .:? "cabal-file-info"
            mcabalFileInfo' <- forM mcabalFileInfo $ \o' -> do
                cfiSize <- Just <$> o' .: "size"
                cfiHashes <- o' .: "hashes"
                cfiHash <- maybe
                                (fail "Could not find SHA256")
                                (return . mkCabalHashFromSHA256)
                            $ HashMap.lookup ("SHA256" :: Text) cfiHashes
                return CabalFileInfo {..}

            Object constraints <- o .: "constraints"

            flags <- constraints .: "flags"
            let flags' = Map.singleton name' flags

            hide <- constraints .:? "hide" .!= False
            let hide' = if hide then Set.singleton name' else Set.empty

            let location = PLIndex $ PackageIdentifierRevision (PackageIdentifier name' version) mcabalFileInfo'

            return (Endo (location:), flags', hide')
loadResolver (ResolverCompiler compiler) = return SnapshotDef
    { sdParent = Left compiler
    , sdResolver = ResolverCompiler compiler
    , sdLocations = []
    , sdDropPackages = Set.empty
    , sdFlags = Map.empty
    , sdHide = Set.empty
    , sdGhcOptions = Map.empty
    }
loadResolver (ResolverCustom name (loc, url)) = do
  $logDebug $ "Loading " <> url <> " build plan"
  case loc of
    Left req -> download' req >>= load
    Right fp -> load fp
  where
    download' :: Request -> m FilePath
    download' req = do
      let urlHash = S8.unpack $ trimmedSnapshotHash $ doHash $ encodeUtf8 url
      hashFP <- parseRelFile $ urlHash ++ ".yaml"
      customPlanDir <- getCustomPlanDir
      let cacheFP = customPlanDir </> $(mkRelDir "yaml") </> hashFP
      void (download req cacheFP :: m Bool)
      return $ toFilePath cacheFP

    getCustomPlanDir = do
        root <- view stackRootL
        return $ root </> $(mkRelDir "custom-plan")

    load :: FilePath -> m SnapshotDef
    load fp = do
      WithJSONWarnings (sd0, WithJSONWarnings parentResolver warnings2) warnings <-
        liftIO (decodeFileEither fp) >>= either
          throwM
          (either (throwM . AesonException) return . parseEither parseCustom)
      logJSONWarnings (T.unpack url) warnings
      logJSONWarnings (T.unpack url) warnings2

      -- The fp above may just be the download location for a URL,
      -- which we don't want to use. Instead, look back at loc from
      -- above.
      let mdir =
            case loc of
              Left _ -> Nothing
              Right fp' -> Just $ takeDirectory fp'
      parentResolver' <- mapM (parseCustomLocation mdir) parentResolver

      -- Calculate the hash of the current file, and then combine it
      -- with parent hashes if necessary below.
      rawHash :: SnapshotHash <- fromDigest <$> hashFile fp :: m SnapshotHash

      (parent', hash') <-
        case parentResolver' of
          ResolverCompiler cv -> return (Left cv, rawHash) -- just a small optimization
          _ -> do
            parent' :: SnapshotDef <- loadResolver (parentResolver' :: Resolver) :: m SnapshotDef
            let hash' :: SnapshotHash
                hash' = combineHash rawHash $
                  case sdResolver parent' of
                    ResolverSnapshot snapName -> snapNameToHash snapName
                    ResolverCustom _ parentHash -> parentHash
                    ResolverCompiler _ -> error "loadResolver: Receieved ResolverCompiler in impossible location"
            return (Right parent', hash')
      return sd0
        { sdParent = parent'
        , sdResolver = ResolverCustom name hash'
        }

    -- | Note that the 'sdParent' and 'sdResolver' fields returned
    -- here are bogus, and need to be replaced with information only
    -- available after further processing.
    parseCustom :: Value
                -> Parser (WithJSONWarnings (SnapshotDef, WithJSONWarnings (ResolverWith Text))) -- FIXME there should only be one WithJSONWarnings
    parseCustom = withObjectWarnings "CustomSnapshot" $ \o -> (,)
        <$> (SnapshotDef (Left (error "loadResolver")) (ResolverSnapshot (LTS 0 0))
            <$> jsonSubWarningsT (o ..:? "packages" ..!= [])
            <*> o ..:? "drop-packages" ..!= Set.empty
            <*> o ..:? "flags" ..!= Map.empty
            <*> o ..:? "hide" ..!= Set.empty
            <*> o ..:? "ghc-options" ..!= Map.empty)
        <*> o ..: "resolver"

    fromDigest :: Digest SHA256 -> SnapshotHash
    fromDigest = SnapshotHash . B64URL.encode . Mem.convert

    combineHash :: SnapshotHash -> SnapshotHash -> SnapshotHash
    combineHash (SnapshotHash x) (SnapshotHash y) = doHash (x <> y)

    snapNameToHash :: SnapName -> SnapshotHash
    snapNameToHash = doHash . encodeUtf8 . renderSnapName

    doHash :: S8.ByteString -> SnapshotHash
    doHash = fromDigest . hash

-- | Fully load up a 'SnapshotDef' into a 'LoadedSnapshot'
loadSnapshot
  :: forall env m.
     (StackMiniM env m, HasConfig env, HasGHCVariant env)
  => SnapshotDef
  -> m LoadedSnapshot
loadSnapshot sd = withCabalLoader $ \loader -> loadSnapshot' loader sd

-- | Fully load up a 'SnapshotDef' into a 'LoadedSnapshot'
loadSnapshot'
  :: forall env m.
     (StackMiniM env m, HasConfig env, HasGHCVariant env)
  => (PackageIdentifierRevision -> IO ByteString)
  -> SnapshotDef
  -> m LoadedSnapshot
loadSnapshot' loadFromIndex (snapshotDefFixes -> sd) = do
    path <- configLoadedSnapshotCache $ sdResolver sd -- FIXME confirm the path is by platform
    $(versionedDecodeOrLoad loadedSnapshotVC) path inner
  where
    inner :: m LoadedSnapshot
    inner = do
      LoadedSnapshot compilerVersion _ globals0 parentPackages0 <-
        either loadCompiler (loadSnapshot' loadFromIndex) $ sdParent sd

      platform <- view platformL

      (packages1, flags, hide, ghcOptions) <- execStateT
        (mapM_ (findPackage loadFromIndex platform compilerVersion) (sdLocations sd))
        (Map.empty, sdFlags sd, sdHide sd, sdGhcOptions sd)

      let toDrop = Map.union (const () <$> packages1) (Map.fromSet (const ()) (sdDropPackages sd))
          globals1 = Map.difference globals0 toDrop
          parentPackages1 = Map.difference parentPackages0 toDrop

          toUpgrade = Set.unions [Map.keysSet flags, hide, Map.keysSet ghcOptions]
          oldNames = Set.union (Map.keysSet globals1) (Map.keysSet parentPackages1)
          extraToUpgrade = Set.difference toUpgrade oldNames

      unless (Set.null extraToUpgrade) $
        error $ "Invalid snapshot definition, the following packages are not found: " ++ show (Set.toList extraToUpgrade)

      let (noLongerGlobals1, globals2) = Map.partitionWithKey
            (\name _ -> name `Set.member` extraToUpgrade)
            globals1
          (globals3, noLongerGlobals2) = splitUnmetDeps globals2
          noLongerGlobals3 = Map.union (Map.mapWithKey globalToSnapshot noLongerGlobals1) noLongerGlobals2

          (noLongerParent, parentPackages2) = Map.partitionWithKey
            (\name _ -> name `Set.member` extraToUpgrade)
            parentPackages1

          allToUpgrade = Map.union noLongerGlobals3 noLongerParent

      upgraded <- fmap Map.fromList
                $ mapM (recalculate compilerVersion flags hide ghcOptions)
                $ Map.toList allToUpgrade

      let packages2 = Map.unions [upgraded, packages1, parentPackages2]
          allAvailable = Map.union
            (lpiVersion <$> globals3)
            (lpiVersion <$> packages2)

      checkDepsMet allAvailable packages2

      return LoadedSnapshot
        { lsCompilerVersion = compilerVersion
        , lsResolver = sdResolver sd
        , lsGlobals = globals3
        , lsPackages = packages2
        }

    -- | Recalculate a 'LoadedPackageInfo' based on updates to flags,
    -- hide values, and GHC options.
    recalculate :: CompilerVersion
                -> Map PackageName (Map FlagName Bool)
                -> Set PackageName -- ^ hide?
                -> Map PackageName [Text] -- ^ GHC options
                -> (PackageName, LoadedPackageInfo PackageLocation)
                -> m (PackageName, LoadedPackageInfo PackageLocation)
    recalculate compilerVersion allFlags allHide allOptions (name, lpi0) = do
      let hide = lpiHide lpi0 || Set.member name allHide -- FIXME allow child snapshot to unhide?
          options = fromMaybe (lpiGhcOptions lpi0) (Map.lookup name allOptions)
      case Map.lookup name allFlags of
        Nothing -> return (name, lpi0 { lpiHide = hide, lpiGhcOptions = options }) -- optimization
        Just flags -> do
          [(gpd, loc)] <- loadGenericPackageDescriptions loadFromIndex $ lpiLocation lpi0
          unless (loc == lpiLocation lpi0) $ error "recalculate location mismatch"
          platform <- view platformL
          let res@(name', lpi) = calculate gpd platform compilerVersion loc flags hide options
          unless (name == name' && lpiVersion lpi0 == lpiVersion lpi) $ error "recalculate invariant violated"
          return res

-- | Ensure that all of the dependencies needed by this package
-- are available in the given Map of packages.
checkDepsMet :: MonadThrow m
             => Map PackageName Version -- ^ all available packages
             -> Map PackageName (LoadedPackageInfo PackageLocation)
             -> m ()
checkDepsMet available m
  | Map.null errs = return ()
  | otherwise = throwM $ UnmetDeps errs
  where
    errs = foldMap (uncurry go) (Map.toList m)

    go :: PackageName
       -> LoadedPackageInfo loc
       -> Map PackageName (Map PackageName (VersionIntervals, Maybe Version))
    go name lpi
      | Map.null errs' = Map.empty
      | otherwise = Map.singleton name errs'
      where
        errs' = foldMap (uncurry goDep) (Map.toList (lpiPackageDeps lpi))

    goDep :: PackageName -> VersionIntervals -> Map PackageName (VersionIntervals, Maybe Version)
    goDep name intervals =
      case Map.lookup name available of
        Nothing -> Map.singleton name (intervals, Nothing)
        Just version
          | version `withinIntervals` intervals -> Map.empty
          | otherwise -> Map.singleton name (intervals, Just version)

-- | Load a snapshot from the given compiler version, using just the
-- information in the global package database.
loadCompiler :: forall env m.
                (StackMiniM env m, HasConfig env)
             => CompilerVersion
             -> m LoadedSnapshot
loadCompiler cv = do
  menv <- getMinimalEnvOverride
  -- FIXME do we need to ensure that the correct GHC is available, or
  -- can we trust the setup code to do that for us?
  m <- ghcPkgDump menv (whichCompiler cv) []
    (conduitDumpPackage .| CL.foldMap (\dp -> Map.singleton (dpGhcPkgId dp) dp))
  return LoadedSnapshot
    { lsCompilerVersion = cv
    , lsResolver = ResolverCompiler cv
    , lsGlobals = toGlobals m
    , lsPackages = Map.empty
    }
  where
    toGlobals :: Map GhcPkgId (DumpPackage () () ())
              -> Map PackageName (LoadedPackageInfo GhcPkgId)
    toGlobals m =
        Map.fromList $ map go $ Map.elems m
      where
        identMap = Map.map dpPackageIdent m

        go :: DumpPackage () () () -> (PackageName, LoadedPackageInfo GhcPkgId)
        go dp =
            (name, lpi)
          where
            PackageIdentifier name version = dpPackageIdent dp

            goDep ghcPkgId =
              case Map.lookup ghcPkgId identMap of
                Nothing -> Map.empty
                Just (PackageIdentifier name' _) -> Map.singleton name' (fromVersionRange C.anyVersion)

            lpi :: LoadedPackageInfo GhcPkgId
            lpi = LoadedPackageInfo
                { lpiVersion = version
                , lpiLocation = dpGhcPkgId dp
                , lpiFlags = Map.empty
                , lpiGhcOptions = []
                , lpiPackageDeps = Map.unions $ map goDep $ dpDepends dp
                , lpiProvidedExes = Set.empty
                , lpiNeededExes = Map.empty
                , lpiExposedModules = Set.fromList $ map (ModuleName . encodeUtf8) $ dpExposedModules dp
                , lpiHide = not $ dpIsExposed dp
                }

type FindPackageS =
    ( Map PackageName (LoadedPackageInfo PackageLocation)
    , Map PackageName (Map FlagName Bool)
    , Set PackageName
    , Map PackageName [Text]
    )

-- | Find the package at the given 'PackageLocation', grab any flags,
-- hidden state, and GHC options from the 'StateT' (removing them from
-- the 'StateT'), and add the newly found package to the contained
-- 'Map'.
findPackage :: forall m env.
               StackMiniM env m
            => (PackageIdentifierRevision -> IO ByteString)
            -> Platform
            -> CompilerVersion
            -> PackageLocation
            -> StateT FindPackageS m ()
findPackage loadFromIndex platform compilerVersion loc0 =
    loadGenericPackageDescriptions loadFromIndex loc0 >>= mapM_ (uncurry go)
  where
    go :: GenericPackageDescription -> PackageLocation -> StateT FindPackageS m ()
    go gpd loc = do
        (m, allFlags, allHide, allOptions) <- get

        case Map.lookup name m of
          Nothing -> return ()
          Just lpi -> throwM $ PackageDefinedTwice name loc (lpiLocation lpi)

        let flags = fromMaybe Map.empty $ Map.lookup name allFlags
            allFlags' = Map.delete name allFlags

            hide = Set.member name allHide
            allHide' = Set.delete name allHide

            options = fromMaybe [] $ Map.lookup name allOptions
            allOptions' = Map.delete name allOptions

            (_name, lpi) = calculate gpd platform compilerVersion loc flags hide options
            m' = Map.insert name lpi m

        put (m', allFlags', allHide', allOptions')
      where
        PackageIdentifier name _version = fromCabalPackageIdentifier $ C.package $ C.packageDescription gpd

-- | Some hard-coded fixes for build plans, hopefully to be irrelevant over
-- time.
snapshotDefFixes :: SnapshotDef -> SnapshotDef
snapshotDefFixes sd | isStackage (sdResolver sd) = sd
    { sdFlags = Map.unionWith Map.union overrides $ sdFlags sd
    }
  where
    overrides = Map.fromList
      [ ($(mkPackageName "persistent-sqlite"), Map.singleton $(mkFlagName "systemlib") False)
      , ($(mkPackageName "yaml"), Map.singleton $(mkFlagName "system-libyaml") False)
      ]

    isStackage (ResolverSnapshot _) = True
    isStackage _ = False
snapshotDefFixes sd = sd

-- | Convert a global 'LoadedPackageInfo' to a snapshot one by
-- creating a 'PackageLocation'.
globalToSnapshot :: PackageName -> LoadedPackageInfo GhcPkgId -> LoadedPackageInfo PackageLocation
globalToSnapshot name lpi = lpi
    { lpiLocation = PLIndex (PackageIdentifierRevision (PackageIdentifier name (lpiVersion lpi)) Nothing)
    }

-- | Split the globals into those which have their dependencies met,
-- and those that don't. This deals with promotion of globals to
-- snapshot when another global has been upgraded already.
splitUnmetDeps :: Map PackageName (LoadedPackageInfo GhcPkgId)
               -> ( Map PackageName (LoadedPackageInfo GhcPkgId)
                   , Map PackageName (LoadedPackageInfo PackageLocation)
                   )
splitUnmetDeps =
    start Map.empty . Map.toList
  where
    start newGlobals0 toProcess0
      | anyAdded = start newGlobals1 toProcess1
      | otherwise = (newGlobals1, Map.mapWithKey globalToSnapshot $ Map.fromList toProcess1)
      where
        (newGlobals1, toProcess1, anyAdded) = loop False newGlobals0 id toProcess0

    loop anyAdded newGlobals front [] = (newGlobals, front [], anyAdded)
    loop anyAdded newGlobals front (x@(k, v):xs)
      | depsMet newGlobals v = loop True (Map.insert k v newGlobals) front xs
      | otherwise = loop anyAdded newGlobals (front . (x:)) xs

    depsMet globals = all (depsMet' globals) . Map.toList . lpiPackageDeps

    depsMet' globals (name, intervals) =
      case Map.lookup name globals of
        Nothing -> False
        Just lpi -> lpiVersion lpi `withinIntervals` intervals

-- | Load the cabal files present in the given
-- 'PackageLocation'. There may be multiple results if dealing with a
-- repository with subdirs, in which case the returned
-- 'PackageLocation' will have just the relevant subdirectory
-- selected.
loadGenericPackageDescriptions
  :: forall m.
     (MonadIO m, MonadThrow m)
  => (PackageIdentifierRevision -> IO ByteString) -- ^ lookup in index
  -> PackageLocation
  -> m [(GenericPackageDescription, PackageLocation)] -- FIXME consider heavy overlap with Stack.Package
loadGenericPackageDescriptions loadFromIndex loc@(PLIndex pir) = do
  bs <- liftIO $ loadFromIndex pir
  gpd <- parseGPD loc bs
  return [(gpd, loc)]

parseGPD :: MonadThrow m
         => PackageLocation -- ^ for error reporting
         -> ByteString -- raw contents
         -> m GenericPackageDescription
parseGPD loc bs =
  case rawParseGPD bs of
    Left e -> throwM $ InvalidCabalFileInSnapshot loc e bs
    Right (_warnings, gpd) -> return gpd

-- | Calculate a 'LoadedPackageInfo' from the given 'GenericPackageDescription'
calculate :: GenericPackageDescription
          -> Platform
          -> CompilerVersion
          -> PackageLocation
          -> Map FlagName Bool
          -> Bool -- ^ hidden?
          -> [Text] -- ^ GHC options
          -> (PackageName, LoadedPackageInfo PackageLocation)
calculate gpd platform compilerVersion loc flags hide options =
    (name, lpi)
  where
    pconfig = PackageConfig
      { packageConfigEnableTests = False
      , packageConfigEnableBenchmarks = False
      , packageConfigFlags = flags -- FIXME check unused flags
      , packageConfigGhcOptions = options -- FIXME refactor Stack.Package, we probably don't need GHC options passed in
      , packageConfigCompilerVersion = compilerVersion
      , packageConfigPlatform = platform
      }
    pd = resolvePackageDescription pconfig gpd
    PackageIdentifier name version = fromCabalPackageIdentifier $ C.package pd
    lpi = LoadedPackageInfo
      { lpiVersion = version
      , lpiLocation = loc
      , lpiFlags = flags
      , lpiGhcOptions = options
      , lpiPackageDeps = Map.map fromVersionRange
                       $ Map.filterWithKey (const . (/= name))
                       $ packageDependencies pd
      , lpiProvidedExes = Set.fromList $ map (ExeName . T.pack . C.exeName) $ C.executables pd
      , lpiNeededExes = Map.mapKeys ExeName
                      $ Map.map fromVersionRange
                      $ packageToolDependencies pd
      , lpiExposedModules = maybe
          Set.empty
          (Set.fromList . map fromCabalModuleName . C.exposedModules)
          (C.library pd)
      , lpiHide = hide
      }
