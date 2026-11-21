-- | Safe text spans for log dates and literal, case-insensitive search matches.
module Sbx.UI.LogPresentation (Span, highlight, dated, chunks) where

import Prelude
import Data.Array as A
import Data.Array.NonEmpty as NEA
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as S
import Data.String.Regex as R
import Data.String.Regex.Flags (noFlags)
import OpenTUI.Renderer (TextSpan)
import Sbx.UI.Time as Time

type Span = { text :: String, match :: Boolean }

highlight :: String -> String -> Array Span
highlight query text =
  let
    terms = A.filter (_ /= "") (S.split (S.Pattern " ") (S.toLower (S.trim query)))
    lower = S.toLower text
    matches i = A.any (\term -> A.any (\start -> start >= 0 && S.take (S.length term) (S.drop start lower) == term) (A.range (i - S.length term + 1) i)) terms
    step acc i =
      let
        hit = matches i
        char = S.take 1 (S.drop i text)
      in
        if hit == acc.hit then acc { text = acc.text <> char }
        else { hit, text: char, spans: acc.spans <> (if acc.text == "" then [] else [ { text: acc.text, match: acc.hit } ]) }
    result = foldl step { hit: false, text: "", spans: [] } (if text == "" then [] else A.range 0 (S.length text - 1))
  in
    result.spans <> (if result.text == "" then [] else [ { text: result.text, match: result.hit } ])

dated :: String -> String -> { date :: String, text :: String }
dated captured text = case R.regex "^\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?\\s+" noFlags of
  Left _ -> { date: Time.timestamp captured, text }
  Right pattern -> case R.match pattern text of
    Nothing -> { date: Time.timestamp captured, text }
    Just found ->
      let
        prefix = fromMaybe "" (NEA.head found)
      in
        { date: Time.timestamp (S.trim prefix), text: S.drop (S.length prefix) text }

chunks :: Boolean -> String -> String -> Int -> Int -> String -> Array TextSpan
chunks timestamps captured query offset width text =
  let
    line = dated captured text
    prefix = if timestamps then line.date <> "  " else ""
    start = min (S.length prefix) offset
    date = S.take width (S.drop start prefix)
    body = S.take (max 0 (width - S.length date)) (S.drop (max 0 (offset - S.length prefix)) line.text)
  in
    map (\span -> { text: span.text, foreground: if span.match then "#ffffff" else "#71717a", background: if span.match then "#8129ff" else "transparent", bold: span.match }) (highlight query date) <>
      map (\span -> { text: span.text, foreground: if span.match then "#ffffff" else "#d4d4d8", background: if span.match then "#8129ff" else "transparent", bold: span.match }) (highlight query body)
