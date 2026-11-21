import { created } from '../../output/Sbx.UI.Time/foreign.js';
// Both dashboards use the same PureScript ancestry layout.
import { layout, position } from '../../output/Sbx.Branch.Graph/index.js';
export function branchGraph(rows) {
  const nodes = layout(rows);
  return nodes.map((node) => ({
    ...node.item,
    created: created(node.item.createdAt),
    graph: position(nodes)(node),
  }));
}
export function segmentPath(segment) {
  const x = 16 + segment.fromLane * 24,
    next = 16 + segment.toLane * 24;
  const start = segment.fromY * 50,
    end = segment.toY * 50;
  if (x === next) return `M ${x} ${start} L ${x} ${end}`;
  return `M ${x} ${start} L ${x} 28 Q ${x} 50 ${x + 12} 50 L ${next} 50`;
}
