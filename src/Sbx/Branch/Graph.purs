-- | Shared ancestry layout for SVG and native terminal branch graphs.
-- | Missing parents and cycles stay disconnected rather than inventing history.
module Sbx.Branch.Graph (Node, Segment, Position, layout, position, empty, palette, terminal) where

import Prelude
import Data.Array as A
import Data.Foldable (foldl)
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Data.Nullable (Nullable, toMaybe)

type Item r = { branch :: String, parent :: Nullable String, createdAt :: Nullable Number | r }
type Node a = { item :: a, index :: Int, lane :: Int, parentIndex :: Int, unknown :: Boolean }
type Segment = { fromLane :: Int, toLane :: Int, fromY :: Int, toY :: Int, color :: String }
type Position = { index :: Int, lane :: Int, lanes :: Int, parentIndex :: Int, unknown :: Boolean, color :: String, segments :: Array Segment }

palette :: Int -> String
palette index = fromMaybe "#8129ff" (A.index [ "#8129ff", "#38bdf8", "#fbbf24", "#f472b6", "#a3e635", "#c084fc" ] (mod index 6))

empty :: Position
empty = { index: 0, lane: 0, lanes: 1, parentIndex: -1, unknown: false, color: palette 0, segments: [] }

layout :: forall r. Array (Item r) -> Array (Node (Item r))
layout items =
  let
    parent item = do
      name <- toMaybe item.parent
      if item.branch == "main" then Nothing else A.find (\p -> p.branch == name) items
    safe seen item =
      if A.elem item.branch seen then false
      else case parent item of
        Nothing -> true
        Just p -> safe (seen <> [ item.branch ]) p
    valid item = safe [] item
    linked item = if valid item then parent item else Nothing
    compareItems a b = compare (if a.branch == "main" then 0 else 1) (if b.branch == "main" then 0 else 1)
      <> compare (fromMaybe 1.0e30 (toMaybe a.createdAt)) (fromMaybe 1.0e30 (toMaybe b.createdAt))
      <> compare a.branch b.branch
    roots = A.sortBy compareItems (A.filter (\item -> isNothing (linked item)) items)
    walk lane item = [ { item, lane } ] <> A.concatMap (walk (lane + 1)) (A.sortBy compareItems (A.filter (\child -> map _.branch (linked child) == Just item.branch) items))
    ordered = A.concatMap (walk 0) roots
  in
    A.mapWithIndex
      ( \index node ->
          { item: node.item
          , index
          , lane: node.lane
          , parentIndex: fromMaybe (-1) (linked node.item >>= \p -> A.findIndex (\n -> n.item.branch == p.branch) ordered)
          , unknown: node.item.branch /= "main" && (not (valid node.item) || isNothing (parent node.item))
          }
      )
      ordered

position :: forall a. Array (Node a) -> Node a -> Position
position nodes node =
  let
    edges = A.mapMaybe
      ( \child -> do
          parent <- A.index nodes child.parentIndex
          let index = node.index
          if index < parent.index || index > child.index then Nothing
          else Just
            { fromLane: parent.lane
            , toLane: if index == child.index then child.lane else parent.lane
            , fromY: if index == parent.index then 1 else 0
            , toY: if index == child.index then 1 else 2
            , color: palette child.index
            }
      )
      nodes
  in
    { index: node.index, lane: node.lane, lanes: 1 + foldl max 0 (map _.lane nodes), parentIndex: node.parentIndex, unknown: node.unknown, color: palette node.index, segments: edges }

terminal :: Position -> Array { text :: String, foreground :: String, background :: String, bold :: Boolean }
terminal p =
  let
    size = p.lanes * 3
    initial = A.replicate size { text: " ", foreground: "#71717a", background: "transparent", bold: false }
    paint cells x text color = fromMaybe cells (A.updateAt x { text, foreground: color, background: "transparent", bold: true } cells)
    stroke cells segment =
      let
        x = segment.fromLane * 3
        end = segment.toLane * 3
        continues = A.any (\other -> other.fromLane == segment.fromLane && other.toY == 2) p.segments
        vertical = paint cells x (if end > x then (if continues then "├" else "╰") else "│") segment.color
      in
        if end <= x then vertical else foldl (\acc col -> paint acc col "─" segment.color) vertical (A.range (x + 1) end)
    lines = foldl stroke initial p.segments
  in
    paint lines (p.lane * 3) (if p.unknown then "◇" else "●") p.color
