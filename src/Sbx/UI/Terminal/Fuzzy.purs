-- | Small fzf-style subsequence matcher. Adjacent letters and matches near
-- | the beginning rank first; no regular expression comes from user input.
module Sbx.UI.Terminal.Fuzzy (score, rank) where

import Prelude
import Data.Array as A
import Data.Maybe (Maybe(..))
import Data.String as S
import Data.String.CodeUnits as CU

score :: String -> String -> Maybe Int
score query value = go (CU.toCharArray (S.toLower query)) (CU.toCharArray (S.toLower value)) 0 0 false
  where
  go needle hay index total previous = case A.uncons needle of
    Nothing -> Just total
    Just n -> case A.uncons hay of
      Nothing -> Nothing
      Just h | n.head == h.head -> go n.tail h.tail (index + 1) (total + if previous then 0 else index + 2) true
      Just h -> go needle h.tail (index + 1) total false

rank :: forall r. String -> Array { branch :: String, database :: String | r } -> Array { branch :: String, database :: String | r }
rank query rows = map _.row $ A.sortBy (\a b -> compare a.score b.score) $ A.mapMaybe (\row -> score query (row.branch <> " " <> row.database) <#> \value -> { row, score: value }) rows
