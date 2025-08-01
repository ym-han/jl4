{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}

module LSP.L4.Rules where

import Base hiding (use)
import L4.Annotation
import L4.Citations
import L4.Evaluate
import qualified L4.Evaluate as Evaluate
import qualified L4.Evaluate.ValueLazy as EvaluateLazy
import qualified L4.EvaluateLazy as EvaluateLazy
import qualified L4.ExactPrint as ExactPrint
import L4.Lexer (PError, PosToken)
import qualified L4.Lexer as Lexer
import qualified L4.Parser as Parser
import qualified L4.Parser.ResolveAnnotation as Resolve
import L4.Parser.SrcSpan
import qualified L4.Print as Print
import L4.Syntax
import L4.TypeCheck (CheckErrorWithContext (..), CheckResult (..), Substitution, applyFinalSubstitution, toResolved)
import qualified L4.TypeCheck as TypeCheck

import Control.Applicative
import Control.Monad.Trans.Maybe
import Data.Hashable (Hashable)
import Data.Monoid (Ap (..))
import qualified Data.Map.Strict as Map
import Data.Map.Monoidal (MonoidalMap)
import qualified Data.Map.Monoidal as MonoidalMap
import qualified Data.Maybe as Maybe
import qualified Base.Text as Text
import qualified Data.Text.Mixed.Rope as Rope
import System.FilePath
import L4.Utils.IntervalMap (IntervalMap)
import qualified L4.Utils.IntervalMap as IVMap
import Development.IDE.Graph
import GHC.Generics (Generically (..))
import LSP.Core.PositionMapping
import LSP.Core.RuleTypes
import LSP.Core.Shake hiding (Log)
import qualified LSP.Core.Shake as Shake
import LSP.Core.Types.Diagnostics
import LSP.L4.SemanticTokens
import LSP.Logger
import LSP.SemanticTokens
import Language.LSP.Protocol.Types
import qualified Language.LSP.Protocol.Types as LSP
import Data.Either (partitionEithers)
import qualified Data.List as List
import System.Directory
import qualified Paths_jl4_core
import qualified L4.Utils.IntervalMap as IV
import UnliftIO

type instance RuleResult GetLexTokens = ([PosToken], Text)
data GetLexTokens = GetLexTokens
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult GetParsedAst = Module Name
data GetParsedAst = GetParsedAst
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult GetReverseDependencies = [NormalizedUri]
data GetReverseDependencies = GetReverseDependenciesNoCallStack
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

pattern GetReverseDependencies :: WithCallStack GetReverseDependencies
pattern GetReverseDependencies = AttachCallStack [] GetReverseDependenciesNoCallStack

type instance RuleResult ListRootDirectory = [NormalizedUri]
data ListRootDirectory = ListRootDirectory
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult ListOwnDirectory = [NormalizedUri]
data ListOwnDirectory = ListOwnDirectory
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

data ImportResult
  = MkImportResult
  { importName :: Name
  , importRange :: Maybe SrcRange
  , moduleUri :: NormalizedUri
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass NFData

type instance RuleResult GetImports = [ImportResult]
data GetImports = GetImports
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult GetTypeCheckDependencies = [(ImportResult, TypeCheckResult)]
data GetTypeCheckDependencies = GetTypeCheckDependencies
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult TypeCheck = TypeCheckResult
data TypeCheck = TypeCheckNoCallstack
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

pattern TypeCheck :: WithCallStack TypeCheck
pattern TypeCheck = AttachCallStack [] TypeCheckNoCallstack

type instance RuleResult SuccessfulTypeCheck = TypeCheckResult
data SuccessfulTypeCheck = SuccessfulTypeCheck
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

data TypeCheckResult = TypeCheckResult
  { module' :: Module  Resolved
  , substitution :: Substitution
  , infoMap :: TypeCheck.InfoMap
  , nlgMap :: TypeCheck.NlgMap
  , scopeMap :: TypeCheck.ScopeMap
  , success :: Bool
  , environment :: TypeCheck.Environment
  , entityInfo :: TypeCheck.EntityInfo
  , infos :: [TypeCheck.CheckErrorWithContext]
  , dependencies :: [TypeCheckResult]
  }
  deriving stock (Generic)

-- | instance that doesn't force the intervalmaps because they're very large and their values are sometimes expensive
instance NFData TypeCheckResult where
  rnf TypeCheckResult {..} =
    rnf module'
    `seq` rnf substitution
    `seq` infoMap
    `seq` nlgMap
    `seq` scopeMap
    `seq` rnf success
    `seq` rnf environment
    `seq` rnf entityInfo
    `seq` rnf infos
    `seq` rnf dependencies

type instance RuleResult Evaluate = [Evaluate.EvalDirectiveResult]
data Evaluate = Evaluate
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult EvaluateLazy = [EvaluateLazy.EvalDirectiveResult]
data EvaluateLazy = EvaluateLazy
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult GetEvaluationDependencies = Evaluate.EvalState
data GetEvaluationDependencies = GetEvaluationDependencies
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult GetLazyEvaluationDependencies = (EvaluateLazy.Environment, [EvaluateLazy.EvalDirectiveResult])
data GetLazyEvaluationDependencies = GetLazyEvaluationDependencies
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult LexerSemanticTokens = [SemanticToken]
data LexerSemanticTokens = LexerSemanticTokens
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult ParserSemanticTokens = [SemanticToken]
data ParserSemanticTokens = ParserSemanticTokens
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult TypeCheckedSemanticTokens = [SemanticToken]
data TypeCheckedSemanticTokens = TypeCheckedSemanticTokens
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult GetSemanticTokens = [SemanticToken]
data GetSemanticTokens = GetSemanticTokens
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult GetRelSemanticTokens = [UInt]
data GetRelSemanticTokens = GetRelSemanticTokens
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

-- TODO:
-- in future we want to have SrcPos |-> Uri s.t. we can resolve
-- relative locations based on the scope, i.e. if we have
-- DECLARE foo <<british nationality act>>
--   IF bar <<sec. 3>>
-- then this should assemble the uri into one link based on
-- an uri scheme described in the original file
type instance RuleResult ResolveReferenceAnnotations = IntervalMap SrcPos (NormalizedUri, Int, Maybe Text)
data ResolveReferenceAnnotations = ResolveReferenceAnnotations
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult GetReferences = ReferenceMapping
data GetReferences = GetReferences
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

type instance RuleResult ExactPrint = Text
data ExactPrint = ExactPrint
  deriving stock (Generic, Show, Eq)
  deriving anyclass (NFData, Hashable)

data ReferenceMapping =
  ReferenceMapping
  { actualToOriginal :: IntervalMap SrcPos Unique
  -- ^ getting the original occurence of a name, based on its reference's source range
  , originalToActual :: MonoidalMap Unique [SrcRange]
  -- ^ getting the source range of all references of an original definition
  }
  deriving stock Generic
  deriving anyclass NFData
  deriving (Semigroup, Monoid) via Generically ReferenceMapping

singletonReferenceMapping :: Unique -> SrcRange -> ReferenceMapping
singletonReferenceMapping originalName actualRange
  = ReferenceMapping
  { actualToOriginal = IV.singleton (IV.srcRangeToInterval actualRange) originalName
  , originalToActual = MonoidalMap.singleton originalName [actualRange]
  }

lookupReference :: SrcPos -> ReferenceMapping -> [SrcRange]
lookupReference pos mapping = do
  (_, n) <- IVMap.search pos mapping.actualToOriginal
  Maybe.fromMaybe [] $ MonoidalMap.lookup n mapping.originalToActual

data Log
  = ShakeLog Shake.Log
  | LogTraverseAnnoError !Text !TraverseAnnoError
  | LogRelSemanticTokenError !Text
  | LogSemanticTokens !Text [SemanticToken]

instance Pretty Log where
  pretty = \ case
    ShakeLog msg -> pretty msg
    LogTraverseAnnoError herald msg -> pretty herald <> ":" <+> pretty (prettyTraverseAnnoError msg)
    LogRelSemanticTokenError msg -> "Semantic Token " <+> pretty msg
    LogSemanticTokens herald toks ->
      "Semantic Tokens of" <+> pretty herald <> line <> indent 2 (vcat (fmap prettyToken toks))
      where
        prettyToken :: SemanticToken -> Doc ann
        prettyToken s =
          pretty s.start._line <> ":" <> pretty s.start._character <> "-"
            <> pretty (s.start._character + s.length)
            <+> pretty s.category

jl4Rules :: FilePath -> Recorder (WithPriority Log) -> Rules ()
jl4Rules rootDirectory recorder = do
  define shakeRecorder $ \GetLexTokens uri -> do
    mRope <- runMaybeT $
      MaybeT (snd <$> use_ GetFileContents uri)
      <|> do
        -- TODO: how do we actually invalidate this VFS file
        -- (except by opening in the same editor session)
        -- do we check the last modified time or smth like that?
        -- I think basically as it is now we don't do anything like
        -- that and the current time check is basically redundant
        file <- hoistMaybe $ uriToNormalizedFilePath uri
        lift $ addVirtualFileFromFS file

    case mRope of
      Nothing -> pure ([mkSimpleFileDiagnostic uri (mkSimpleDiagnostic (fromNormalizedUri uri).getUri "could not obtain file contents" Nothing)], Nothing)
      Just rope -> do
        let contents = Rope.toText rope
        case Lexer.execLexer uri contents of
          Left errs -> do
            let diags = toList $ fmap mkParseErrorDiagnostic errs
            pure (fmap (mkSimpleFileDiagnostic uri) diags, Nothing)
          Right ts ->
            pure ([], Just (ts, contents))

  define shakeRecorder $ \GetParsedAst uri -> do
    (tokens, contents) <- use_ GetLexTokens uri
    case Parser.execProgramParserForTokens uri contents tokens of
      Left errs -> do
        let
          diags = toList $ fmap mkParseErrorDiagnostic errs
        pure (fmap (mkSimpleFileDiagnostic uri) diags , Nothing)
      Right (prog, warns) -> do
        let
          diags = fmap mkNlgWarning warns

        pure (fmap (mkSimpleFileDiagnostic uri) diags, Just prog)

  define shakeRecorder $ \GetImports uri -> do
    let -- NOTE: we curently don't allow any relative or absolute file paths, just bare module names
        mkImportPath :: Import Name -> Action (Maybe SrcRange, String, [FilePath], Maybe FilePath)
        mkImportPath (MkImport a n _mr) = do

          let modName = takeBaseName $ Text.unpack $ rawNameToText $ rawName n
          paths <- catMaybes <$> do
            -- NOTE: if the current URI is a file uri, we first check the directory relative to the current file
            --
            let relPath = do
                  dir <- takeDirectory . fromNormalizedFilePath <$> uriToNormalizedFilePath uri
                  pure $ dir </> modName <.> "l4"

            let rootPath = rootDirectory </> modName <.> "l4"

            builtinPath <- do
              dataDir <- liftIO Paths_jl4_core.getDataDir
              pure $ dataDir </> "libraries" </> modName <.> "l4"

            pure [Just rootPath, relPath, Just builtinPath]

          existingPaths <- runMaybeT do

            let guardExists pth = do
                  guard =<< liftIO (doesFileExist pth)
                  pure pth

            asum $ guardExists <$> paths

          pure (rangeOf a, modName, paths, existingPaths)

        mkImportUri (range, modName, pths, mfp) = case mfp of
          Just fp -> do
            let u = toNormalizedUri $ filePathToUri fp
            pure ([], range, u)
          Nothing ->
            let diag = mkSimpleFileDiagnostic uri
                  $ mkSimpleDiagnostic
                    (fromNormalizedUri uri).getUri
                    (Text.unlines
                      [ "I could not find a module with this name: " <> Text.pack modName
                      , "I have tried the following paths:"
                      , Text.intercalate ",\n" (map Text.pack pths)
                      ])
                    (fromSrcRange <$> range)
             in pure ([diag], range, uri)

        mkDiagsAndImports :: TopDecl Name -> Ap Action [([FileDiagnostic], ImportResult)]
        mkDiagsAndImports = \ case
          Import _a i@(MkImport _ n _) -> Ap do
            (diag, r, u) <- liftIO . mkImportUri =<< mkImportPath i
            pure [(diag, MkImportResult n r u)]
          _ -> pure []


    prog <- use_ GetParsedAst uri
    (diags, imports) <- fmap unzip $ getAp $ foldTopDecls mkDiagsAndImports prog
    pure (concat diags, Just imports)

  defineWithCallStack shakeRecorder $ \GetTypeCheckDependencies cs uri -> do
    imports <- use_  GetImports uri
    ress    <- fmap catMaybes $ zipWith (\res mres -> (res,) <$> mres) imports <$> uses (AttachCallStack cs TypeCheckNoCallstack) (map (.moduleUri) imports)
    pure ([], Just ress)

  defineWithCallStack shakeRecorder $ \TypeCheckNoCallstack cs uri -> do
    parsed       <- use_ GetParsedAst uri
    (imported, dependencies) <- unzip <$> use_ (AttachCallStack (uri : cs) GetTypeCheckDependencies) uri

    let parsedAndAnnotated = overImports (updateImport $ map (\res -> (res.importName, res.moduleUri)) imported) parsed

    let unionCheckStates :: TypeCheck.CheckState -> TypeCheckResult -> TypeCheck.CheckState
        unionCheckStates cState tcRes =
          TypeCheck.MkCheckState
          { substitution = tcRes.substitution
          , supply = cState.supply
          , infoMap = IV.empty
          , nlgMap = IV.empty
          , scopeMap = IV.empty
          }
        unionCheckEnv cEnv tcRes =
          TypeCheck.MkCheckEnv
            -- NOTE: the environments behave more like sets than like lists, that's why we need to union them
            { environment = Map.unionWith List.union cEnv.environment tcRes.environment
            -- NOTE: we assume that if we have a mapping from a specific unique then it must have come from the
            -- same module. That means that the rhs of it should be identical.
            , entityInfo = Map.unionWith (\t1 t2 -> assert (t1 == t2) t1) cEnv.entityInfo tcRes.entityInfo
            , errorContext = cEnv.errorContext
            , moduleUri = cEnv.moduleUri
            , functionTypeSigs = Map.empty -- we can omit environments that are only used internally
            , declTypeSigs = Map.empty
            , declareDeclarations = Map.empty
            , assumeDeclarations = Map.empty
            , sectionStack = []
            }
        -- NOTE: we don't want to leak the inference variables from the substitution
        initCheckState = set #substitution Map.empty $ foldl' unionCheckStates TypeCheck.initialCheckState dependencies
        initCheckEnv = foldl' unionCheckEnv (TypeCheck.initialCheckEnv uri) dependencies
        result = TypeCheck.doCheckProgramWithDependencies initCheckState initCheckEnv parsedAndAnnotated
        (infos, errors) = partition ((== TypeCheck.SInfo) . TypeCheck.severity) result.errors
    pure
      ( fmap (checkErrorToDiagnostic >>= mkFileDiagnosticWithSource uri) result.errors
      , Just TypeCheckResult
        { module' = result.program
        , substitution = result.substitution
        , environment = result.environment
        , entityInfo = applyFinalSubstitution result.substitution uri result.entityInfo
        , success = null errors
        , infos
        , infoMap = result.infoMap
        , nlgMap = result.nlgMap
        , scopeMap = result.scopeMap
        , dependencies = dependencies <> foldMap (.dependencies) dependencies
        }
      )

  define shakeRecorder \ListRootDirectory _emptyUri -> do
    cts <- liftIO $ listL4Files rootDirectory
    pure ([], Just cts)

  define shakeRecorder \ListOwnDirectory uri -> do
    case fromNormalizedFilePath <$> uriToNormalizedFilePath uri of
      Nothing -> pure ([], Just [])
      Just fp -> liftIO do
        uris <- listL4Files $ takeDirectory fp
        pure ([], Just uris)

  -- NOTE: currently it's not possible to get references coming from the original reference
  defineWithCallStack shakeRecorder $ \GetReverseDependenciesNoCallStack cs uri -> do
    potentialDependencies <-
      (<>)
        <$> useNoFile_ ListRootDirectory
        <*> use_ ListOwnDirectory uri
    importers <-
      mapMaybe
        (\(importerUri, imports) -> if uri `elem` map (.moduleUri) imports then Just importerUri else Nothing)
       . zip potentialDependencies
       <$> uses_ GetImports potentialDependencies
    transitiveImporters <- concat <$> uses_ (AttachCallStack (uri : cs) GetReverseDependenciesNoCallStack) importers
    pure ([], Just $ importers <> transitiveImporters)

  define shakeRecorder $ \SuccessfulTypeCheck f -> do
    typeCheckResult <- use_ TypeCheck f
    if typeCheckResult.success
      then pure ([], Just typeCheckResult)
      else pure ([], Nothing)

  defineWithCallStack shakeRecorder $ \GetEvaluationDependencies cs f -> do
    imports <- use_  GetImports f
    tcRes   <- use_  SuccessfulTypeCheck f
    -- TODO: when checking for cycles, we should check which one is the
    -- first element in the cycle that is, i.e. which IMPORT, then scan
    -- for the IMPORT again and
    -- put the diagnostic on that IMPORT
    deps    <- fmap catMaybes $ uses (AttachCallStack (f : cs) GetEvaluationDependencies) $ map (.moduleUri) imports
    let environment = Evaluate.unionEnvironments $ map (.environment) deps
        own = execEvalModuleWithEnv environment tcRes.module'
    pure ([], Just own)

  defineWithCallStack shakeRecorder $ \GetLazyEvaluationDependencies cs f -> do
    imports <- use_  GetImports f
    tcRes   <- use_  SuccessfulTypeCheck f
    -- TODO: when checking for cycles, we should check which one is the
    -- first element in the cycle that is, i.e. which IMPORT, then scan
    -- for the IMPORT again and
    -- put the diagnostic on that IMPORT
    deps    <- fmap catMaybes $ uses (AttachCallStack (f : cs) GetLazyEvaluationDependencies) $ map (.moduleUri) imports
    let environment = mconcat (fst <$> deps)
    (ownEnv, ownDirectives) <- liftIO (EvaluateLazy.execEvalModuleWithEnv environment tcRes.module')
    pure ([], Just (ownEnv <> environment, ownDirectives))

  define shakeRecorder $ \Evaluate uri -> do
    res  <- use_ (AttachCallStack [uri] GetEvaluationDependencies) uri
    let results = res.directiveResults
    pure (mkSimpleFileDiagnostic uri . evalResultToDiagnostic <$> results, Just results)

  define shakeRecorder $ \EvaluateLazy uri -> do
    res  <- use_ (AttachCallStack [uri] GetLazyEvaluationDependencies) uri
    let results = snd res
    pure (mkSimpleFileDiagnostic uri . evalLazyResultToDiagnostic <$> results, Just results)

  define shakeRecorder $ \LexerSemanticTokens f -> do
    (tokens, _) <- use_ GetLexTokens f
    case runSemanticTokensM (defaultSemanticTokenCtx ()) tokens of
      Left err -> do
        logWith recorder Error $ LogTraverseAnnoError "Lexer" err
        pure ([], Nothing)
      Right tokenized -> do
        pure ([], Just tokenized)

  define shakeRecorder $ \ParserSemanticTokens f -> do
    prog <- use_ GetParsedAst f
    case runSemanticTokensM (defaultSemanticTokenCtx CValue) prog of
      Left err -> do
        logWith recorder Error $ LogTraverseAnnoError "Parser" err
        pure ([], Nothing)
      Right tokenized -> do
        pure ([], Just tokenized)

  define shakeRecorder $ \TypeCheckedSemanticTokens f -> do
    tcRes <- use_ SuccessfulTypeCheck f
    case runSemanticTokensM (defaultSemanticTokenCtx ()) tcRes.module' of
      Left err -> do
        logWith recorder Error $ LogTraverseAnnoError "TypeCheck" err
        pure ([], Nothing)
      Right tokenized -> do
        pure ([], Just tokenized)

  define shakeRecorder $ \GetSemanticTokens f -> do
    toks <-
      semanticTokensUsing
        -- Order matters, 'SemanticTokens' earlier in the list are preferred over later ones.
        [ useWithOptionalStale TypeCheckedSemanticTokens
        , useWithOptionalStale ParserSemanticTokens
        , useWithOptionalStale LexerSemanticTokens
        ]
        f
    pure ([], Just toks)

  define shakeRecorder $ \GetRelSemanticTokens f -> do
    tokens <- use_ GetSemanticTokens f
    let semanticTokens = relativizeTokens $ fmap toSemanticTokenAbsolute tokens
    case encodeTokens defaultSemanticTokensLegend semanticTokens of
      Left err -> do
        logWith recorder Error $ LogRelSemanticTokenError err
        pure ([], Nothing)
      Right relSemTokens ->
          pure ([], Just relSemTokens)
  define shakeRecorder $ \ResolveReferenceAnnotations uri -> case uriToNormalizedFilePath uri of
    -- TODO: this should load citations from a "central place" as long as we don't
    -- support citations directly in the file
    Nothing -> pure ([], Nothing)
    Just f -> do
      ownPath <- normalizedFilePathToOsPath f
      (tokens, _) <- use_ GetLexTokens uri

      -- obtain a valid relative file path from the ref-src annos and
      -- parse the file contents from csv into intervalmaps from the sources of
      -- the annos to the reference they represent
      refSrcs <- liftIO
        $ traverse
          (\n -> runExceptT do
             refSrc <- withRefSrc ownPath n
             let refMap = withRefMap n
             pure (refSrc <> refMap)
          )
          tokens

      -- report any errors encountered while parsing any of the ref-src annos,
      -- annotate them on the ref-src annos they originated from and finally
      -- union all interval maps
      let (errs, references) = partitionEithers refSrcs

          mkReferencesFromNonempty v
            | null v = Nothing
            | otherwise = Just $ mkReferences tokens v

          mps = case Maybe.mapMaybe mkReferencesFromNonempty references of
            [] -> Nothing
            xs -> Just $ mconcat xs

          diags = map (uncurry mkDiagnostic) errs

          mkDiagnostic loc err =
            FileDiagnostic
              { fdLspDiagnostic =
                Diagnostic
                  { _source = Just "jl4"
                  , _severity = Just DiagnosticSeverity_Warning
                  , _range = srcRangeToLspRange $ Just loc
                  , _message = Text.pack err
                  , _relatedInformation = Nothing
                  , _data_ = Nothing
                  , _codeDescription = Nothing
                  , _tags = Nothing
                  , _code = Nothing
                  }
              , fdFilePath = uri
              , fdShouldShowDiagnostic = ShowDiag
              , fdOriginalSource = NoMessage
              }

      pure (diags, mps)

  define shakeRecorder $ \GetReferences uri -> do
    tcRes <- use_ TypeCheck uri

    let spanOf resolved
          = maybe
              mempty
              (singletonReferenceMapping $ getUnique resolved)
              -- NOTE: the source range of the actual Name
              (rangeOf resolved)

        refMapping :: ReferenceMapping
          = foldMap spanOf
          $ toResolved tcRes.module'
            <> foldMap (toResolved . (.module')) tcRes.dependencies

    pure ([], Just refMapping)

  define shakeRecorder $ \ExactPrint f -> do
    parsed <- use_ GetParsedAst f
    let pfp = (fromNormalizedUri f).getUri
    pure case ExactPrint.exactprint parsed of
      Left trErr -> ([mkSimpleFileDiagnostic f $ mkSimpleDiagnostic pfp (prettyTraverseAnnoError trErr) Nothing], Nothing)
      Right ep'd -> ([], Just ep'd)

  where
    shakeRecorder = cmapWithPrio ShakeLog recorder
    mkSimpleFileDiagnostic nfp diag =
      FileDiagnostic
        { fdFilePath = nfp
        , fdShouldShowDiagnostic = ShowDiag
        , fdLspDiagnostic = diag
        , fdOriginalSource = NoMessage
        }

    mkFileDiagnosticWithSource nfp diag orig =
      FileDiagnostic
        { fdFilePath = nfp
        , fdShouldShowDiagnostic = ShowDiag
        , fdLspDiagnostic = diag
        , fdOriginalSource = MkSomeMessage orig
        }

    mkNlgWarning :: Resolve.Warning -> Diagnostic
    mkNlgWarning warn =
        Diagnostic
          { _range = rangeOfResolveWarning warn
          , _severity = Just LSP.DiagnosticSeverity_Warning
          , _code = Nothing
          , _codeDescription = Nothing
          , _source = Just "parser"
          , _message = prettyNlgResolveWarning warn
          , _tags = Nothing
          , _relatedInformation = Nothing
          , _data_ = Nothing
          }

    mkParseErrorDiagnostic :: PError -> Diagnostic
    mkParseErrorDiagnostic parseError = mkSimpleDiagnostic parseError.origin parseError.message (Just parseError.range)

    mkSimpleDiagnostic :: Text -> Text -> Maybe SrcSpan -> Diagnostic
    mkSimpleDiagnostic origin _message range =
      Diagnostic
        { _range = srcSpanToLspRange range
        , _severity = Just LSP.DiagnosticSeverity_Error
        , _code = Nothing
        , _codeDescription = Nothing
        , _source = Just origin
        , _message
        , _tags = Nothing
        , _relatedInformation = Nothing
        , _data_ = Nothing
        }

    evalResultToDiagnostic :: EvalDirectiveResult -> Diagnostic
    evalResultToDiagnostic (MkEvalDirectiveResult range res _trace) = do
      Diagnostic
        { _range = srcRangeToLspRange (Just range)
        , _severity = Just LSP.DiagnosticSeverity_Information
        , _code = Nothing
        , _codeDescription = Nothing
        , _source = Just "eval"
        , _message = either (Text.unlines . prettyEvalException) Print.prettyLayout res
        , _tags = Nothing
        , _relatedInformation = Nothing
        , _data_ = Nothing
        }

    evalLazyResultToDiagnostic :: EvaluateLazy.EvalDirectiveResult -> Diagnostic
    evalLazyResultToDiagnostic (EvaluateLazy.MkEvalDirectiveResult range res) = do
      Diagnostic
        { _range = srcRangeToLspRange range
        , _severity = Just LSP.DiagnosticSeverity_Information
        , _code = Nothing
        , _codeDescription = Nothing
        , _source = Just "eval"
        , _message = either (Text.unlines . EvaluateLazy.prettyEvalException) Print.prettyLayout res
        , _tags = Nothing
        , _relatedInformation = Nothing
        , _data_ = Nothing
        }

    checkErrorToDiagnostic :: CheckErrorWithContext -> Diagnostic
    checkErrorToDiagnostic checkError =
      Diagnostic
        { _range = srcRangeToLspRange (rangeOf checkError)
        , _severity = Just (translateSeverity (TypeCheck.severity checkError))
        , _code = Nothing
        , _codeDescription = Nothing
        , _source = Just "check"
        , _message = Text.unlines (TypeCheck.prettyCheckError checkError.kind)
        , _tags = Nothing
        , _relatedInformation = Nothing
        , _data_ = Nothing
        }

translateSeverity :: TypeCheck.Severity -> DiagnosticSeverity
translateSeverity TypeCheck.SInfo  = LSP.DiagnosticSeverity_Information
translateSeverity TypeCheck.SWarn  = LSP.DiagnosticSeverity_Warning
translateSeverity TypeCheck.SError = LSP.DiagnosticSeverity_Error

srcRangeToLspRange :: Maybe SrcRange -> LSP.Range
srcRangeToLspRange Nothing = LSP.Range (LSP.Position 0 0) (LSP.Position 0 0)
srcRangeToLspRange (Just range) = LSP.Range (srcPosToLspPosition range.start) (srcPosToLspPosition range.end)

pointRange :: Position -> Range
pointRange pos = Range pos pos

srcSpanToLspRange :: Maybe SrcSpan -> LSP.Range
srcSpanToLspRange Nothing = LSP.Range (LSP.Position 0 0) (LSP.Position 0 0)
srcSpanToLspRange (Just range) = LSP.Range (srcPosToLspPosition range.start) (srcPosToLspPosition range.end)

srcPosToLspPosition :: SrcPos -> LSP.Position
srcPosToLspPosition s =
  LSP.Position
    { _character = fromIntegral $ s.column - 1
    , _line = fromIntegral $ s.line - 1
    }

lspPositionToSrcPos :: LSP.Position -> SrcPos
lspPositionToSrcPos (LSP.Position { _character = c, _line = l }) =
  MkSrcPos (fromIntegral $ l + 1) (fromIntegral $ c + 1)

prettyNlgResolveWarning :: Resolve.Warning -> Text
prettyNlgResolveWarning = \ case
  Resolve.NotAttached _ ->
    "Not attached to any valid syntax node."
  Resolve.UnknownLocation nlg -> Text.unlines
    [ "The following NLG Annotation has no source location. This might be an internal compiler error."
    , "```"
    , Print.prettyLayout nlg
    , "```"
    ]
  Resolve.Ambiguous name nlgs -> Text.unlines $
    [ "More than one NLG annotation attached to: " <> Print.prettyLayout name
    , "The following annotations would be attached:"
    , ""
    ] <> [ "* `" <> Print.prettyLayout n.payload <> "`" | n <- nlgs]

listL4Files :: FilePath -> IO [NormalizedUri]
listL4Files dir = do
  files <- filterM doesFileExist . map (dir </>) =<< listDirectory dir
  pure $ toNormalizedUri . filePathToUri <$> filter ((== ".l4") . takeExtension) files


rangeOfResolveWarning :: Resolve.Warning -> LSP.Range
rangeOfResolveWarning = \ case
  Resolve.NotAttached nlg ->
    srcSpanToLspRange $ Just nlg.range
  Resolve.UnknownLocation _ ->
    srcSpanToLspRange Nothing
  Resolve.Ambiguous name _ ->
    srcRangeToLspRange $ rangeOf name

-- ----------------------------------------------------------------------------
-- Helpers for implementing syntax highlighting
-- ----------------------------------------------------------------------------

-- | Similar to 'useWithStale', but instead of returning a 'zeroMapping' for 'PositionMapping'
-- when the rule is up-to-date, we return 'Nothing', to indicate that this rule is not stale.
--
-- We use this to implement short-circuting in semantic token generation.
useWithOptionalStale :: IdeRule k v => k -> NormalizedUri ->  Action (Maybe (v, Maybe PositionMapping))
useWithOptionalStale f nuri = do
  r <- use f nuri
  case r of
    Nothing -> do
      toks <- useWithStale f nuri
      pure $ fmap (fmap Just) toks
    Just toks ->
      pure $ Just (toks, Nothing)

applyPositionMapping :: [SemanticToken] -> PositionMapping -> [SemanticToken]
applyPositionMapping semTokens positionMapping =
  Maybe.mapMaybe
    ( \t ->
        case toCurrentPosition positionMapping t.start of
          Nothing -> Nothing
          Just newPos -> Just (t & #start .~ newPos)
    )
    semTokens

-- | @'semanticTokensUsing' phases@
--
-- Helper function for defining multi-phase semantic syntax highlighting.
--
-- Each phase can produce '[SemanticToken]'s and 'PositionMapping' if the result is outdated.
-- Tokens obtained from earlier phases take precedence over tokens from later phases.
--
-- If one of the phases is up-to-date, i.e. 'Maybe PositionMapping' is 'Nothing',
-- then we don't run later phases.
semanticTokensUsing ::
  [NormalizedUri -> Action (Maybe ([SemanticToken], Maybe PositionMapping))] ->
  (NormalizedUri -> Action [SemanticToken])
semanticTokensUsing phases uri = do
  (_, tokens) <- foldM go (False, []) phases
  pure tokens
 where
  -- Just like a fold, but with short circuiting behaviour.
  go (True, earlierTokens) _phase = pure (True, earlierTokens)
  go (False, earlierTokens) phase = do
    tokens <- phase uri
    case tokens of
      Nothing -> do
        pure (False, earlierTokens)
      Just (toks, mpm) -> case mpm of
        Nothing -> pure (True, mergeSameLengthTokens earlierTokens toks)
        Just pm -> pure (False, mergeSameLengthTokens earlierTokens (applyPositionMapping toks pm))

  -- We assume that semantic tokens do *not* change its length, no matter whether they
  -- have been lexed, parsed or typechecked.
  -- A rather bold assumption, tbh. It will almost definitely not hold
  -- up in practice, but let's do one step at a time.
  mergeSameLengthTokens :: [SemanticToken] -> [SemanticToken] -> [SemanticToken]
  mergeSameLengthTokens [] bs = bs
  mergeSameLengthTokens as [] = as
  mergeSameLengthTokens (a : as) (b : bs) = case compare a.start b.start of
    -- a.start == b.start
    -- Same token, only print one
    EQ -> a : mergeSameLengthTokens as bs
    -- a.start < b.start
    LT -> a : mergeSameLengthTokens as (b : bs)
    -- a.start > b.start
    GT -> b : mergeSameLengthTokens (a : as) bs
