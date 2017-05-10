{-# LANGUAGE RankNTypes #-}
module Renderer.TOC
( toc
, diffTOC
, JSONSummary(..)
, Summarizable(..)
, isErrorSummary
, Declaration(..)
, DeclarationType(..)
, declaration
, Entry(..)
, tableOfContentsBy
) where

import Category as C
import Data.Aeson
import Data.Align (crosswalk)
import Data.Functor.Both hiding (fst, snd)
import qualified Data.Functor.Both as Both
import Data.Text (toLower)
import Data.Record
import Diff
import Info
import Prologue
import Renderer.Summary (Summaries(..))
import qualified Data.List as List
import qualified Data.Map as Map hiding (null)
import Source hiding (null)
import Syntax as S
import Term
import Patch

data JSONSummary = JSONSummary { info :: Summarizable }
                 | ErrorSummary { error :: Text, errorSpan :: SourceSpan }
                 deriving (Generic, Eq, Show)

instance ToJSON JSONSummary where
  toJSON (JSONSummary Summarizable{..}) = object [ "changeType" .= summarizableChangeType, "category" .= toCategoryName summarizableCategory, "term" .= summarizableTermName, "span" .= summarizableSourceSpan ]
  toJSON ErrorSummary{..} = object [ "error" .= error, "span" .= errorSpan ]

isErrorSummary :: JSONSummary -> Bool
isErrorSummary ErrorSummary{} = True
isErrorSummary _ = False

data DiffInfo = DiffInfo
  { infoCategory :: Maybe Category
  , infoName :: Text
  , infoSpan :: SourceSpan
  }
  deriving (Eq, Show)

data TOCSummary a = TOCSummary
  { summaryPatch :: Patch a
  , parentInfo :: Maybe Summarizable
  }
  deriving (Eq, Functor, Show, Generic)

data Summarizable
  = Summarizable
    { summarizableCategory :: Category
    , summarizableTermName :: Text
    , summarizableSourceSpan :: SourceSpan
    , summarizableChangeType :: Text
    }
  deriving (Eq, Show)

-- | A declaration’s identifier and type.
data Declaration = Declaration { declarationIdentifier :: Text, declarationType :: DeclarationType }
  deriving (Eq, Show)

-- | The type of a declaration.
data DeclarationType = Method | Function | Class
  deriving (Eq, Show)

-- | Produce the annotations of nodes representing declarations.
declaration :: HasField fields (Maybe Declaration) => TermF (Syntax Text) (Record fields) a -> Maybe (Record fields)
declaration (annotation :< _) = annotation <$ (getField annotation :: Maybe Declaration)


-- | An entry in a table of contents.
data Entry a
  = Unchanged a       -- ^ An entry for an unchanged portion of a diff (i.e. a diff node not containing any patches).
  | Changed a         -- ^ An entry for a node containing changes.
  | Patched (Patch a) -- ^ An entry for a change occurring inside a 'Patch'.
  deriving (Eq, Show)

-- | Compute a table of contents for a diff characterized by a function mapping relevant nodes onto values in Maybe.
tableOfContentsBy :: Traversable f
                  => (forall b. TermF f annotation b -> Maybe a) -- ^ A function mapping relevant nodes onto values in Maybe.
                  -> Diff f annotation                           -- ^ The diff to compute the table of contents for.
                  -> [Entry a]                                   -- ^ A list of entries for relevant changed and unchanged nodes in the diff.
tableOfContentsBy selector = fromMaybe [] . iter diffAlgebra . fmap (Just . fmap Patched . crosswalk (cata termAlgebra))
  where diffAlgebra r | Just a <- selector (first Both.snd r) = Just (maybe [Unchanged a] (maybe [Changed a] (uncurry (:)) . uncons) (fold r))
                      | otherwise = fold r
        termAlgebra r | Just a <- selector r = [a]
                      | otherwise = fold r

toc :: HasDefaultFields fields => Both SourceBlob -> Diff (Syntax Text) (Record fields) -> Summaries
toc blobs diff = Summaries changes errors
  where
    changes = if null changes' then mempty else Map.singleton summaryKey (toJSON <$> changes')
    errors = if null errors' then mempty else Map.singleton summaryKey (toJSON <$> errors')
    (errors', changes') = List.partition isErrorSummary summaries
    summaries = diffTOC blobs diff

    summaryKey = toS $ case runJoin (path <$> blobs) of
      (before, after) | null before -> after
                      | null after -> before
                      | before == after -> after
                      | otherwise -> before <> " -> " <> after

diffTOC :: HasDefaultFields fields => Both SourceBlob -> Diff (Syntax Text) (Record fields) -> [JSONSummary]
diffTOC blobs = removeDupes . diffToTOCSummaries >=> toJSONSummaries
  where
    removeDupes :: [TOCSummary DiffInfo] -> [TOCSummary DiffInfo]
    removeDupes = foldl' go []
      where
        go xs x | (_, _ : _) <- find exactMatch x xs = xs
                | (front, TOCSummary _ (Just info) : back) <- find similarMatch x xs =
                  front <> (x { parentInfo = Just (info { summarizableChangeType = "modified" }) } : back)
                | otherwise = xs <> [x]
        find p x = List.break (p x)
        exactMatch a b = parentInfo a == parentInfo b
        similarMatch a b = case (parentInfo a, parentInfo b) of
          (Just (Summarizable catA nameA _ _), Just (Summarizable catB nameB _ _)) -> catA == catB && toLower nameA == toLower nameB
          (_, _) -> False

    diffToTOCSummaries = para $ \diff -> case diff of
      Free (Join (_, annotation) :< syntax)
        | Just identifier <- identifierFor diffSource diffUnwrap syntax ->
          foldMap (fmap (contextualize (Summarizable (category annotation) identifier (sourceSpan annotation) "modified")) . snd) syntax
        | otherwise -> foldMap snd syntax
      Pure patch -> fmap summarize (sequenceA (runBothWith mapPatch (toInfo . source <$> blobs) patch))

    summarize patch = TOCSummary patch (infoCategory >>= summarizable)
      where DiffInfo{..} = afterOrBefore patch
            summarizable category = Summarizable category infoName infoSpan (patchType patch) <$ find (category ==) [C.Function, C.Method, C.SingletonMethod]

    contextualize info summary = summary { parentInfo = Just (fromMaybe info (parentInfo summary)) }

    diffSource diff = case runFree diff of
      Free (Join (_, a) :< r) -> termFSource (source (Both.snd blobs)) (a :< r)
      Pure a -> termFSource (source (Both.snd blobs)) (runCofree (afterOrBefore a))


toInfo :: HasDefaultFields fields => Source -> Term (Syntax Text) (Record fields) -> [DiffInfo]
toInfo source = para $ \ (annotation :< syntax) -> let termName = fromMaybe (textFor source (byteRange annotation)) (identifierFor (termFSource source . runCofree) (Just . tailF . runCofree) syntax) in case syntax of
  S.ParseError{} -> [DiffInfo Nothing termName (sourceSpan annotation)]
  S.Indexed{} -> foldMap snd syntax
  S.Fixed{} -> foldMap snd syntax
  S.Commented{} -> foldMap snd syntax
  S.AnonymousFunction{} -> [DiffInfo (Just C.AnonymousFunction) termName (sourceSpan annotation)]
  _ -> [DiffInfo (Just (category annotation)) termName (sourceSpan annotation)]

identifierFor :: (a -> Text) -> (a -> Maybe (Syntax Text a)) -> Syntax Text (a, b) -> Maybe Text
identifierFor getSource unwrap syntax = case syntax of
  S.Function (identifier, _) _ _ -> Just $ getSource identifier
  S.Method _ (identifier, _) Nothing _ _ -> Just $ getSource identifier
  S.Method _ (identifier, _) (Just (receiver, _)) _ _
    | Just (S.Indexed [receiverParams]) <- unwrap receiver
    , Just (S.ParameterDecl (Just ty) _) <- unwrap receiverParams -> Just $ "(" <> getSource ty <> ") " <> getSource identifier
    | otherwise -> Just $ getSource receiver <> "." <> getSource identifier
  _ -> Nothing

diffUnwrap :: Diff f (Record fields) -> Maybe (f (Diff f (Record fields)))
diffUnwrap diff = case runFree diff of
  Free (_ :< syntax) -> Just syntax
  _ -> Nothing

termFSource :: HasField fields Range => Source -> TermF f (Record fields) a -> Text
termFSource source = toText . flip Source.slice source . byteRange . headF

textFor :: Source -> Range -> Text
textFor source = toText . flip Source.slice source

toJSONSummaries :: TOCSummary DiffInfo -> [JSONSummary]
toJSONSummaries TOCSummary{..} = case infoCategory of
  Nothing -> [ErrorSummary infoName infoSpan]
  _ -> maybe [] (pure . JSONSummary) parentInfo
  where DiffInfo{..} = afterOrBefore summaryPatch

-- The user-facing category name
toCategoryName :: Category -> Text
toCategoryName category = case category of
  C.SingletonMethod -> "Method"
  c -> show c
