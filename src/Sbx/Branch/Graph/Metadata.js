import {created} from '../Sbx.UI.Time/foreign.js';
import {runCli} from '@bsdkrun/sdk';
import {async} from '../Bsdkrun.Internal/foreign.js';
export function epoch(value) {
  if(value == null || value === '') return null;
  const number=typeof value==='number'||/^\d+(\.\d+)?$/.test(value)?Number(value):Date.parse(value)/1000;
  return Number.isFinite(number) && number >= 0 ? (number>1e12?number/1000:number) : null;
}
export const listImpl = async(async signal => {
  const result=await runCli(['zfs','ls','--json'],{signal});
  if(result.exitCode!==0)throw Error(result.stderr || 'Cannot list ZFS branches');
  return JSON.parse(result.stdout || '[]').map(volume=>({
    name:String(volume.name),path:String(volume.path || ''),sizeBytes:Number(volume.size_bytes || 0),size:volume.size ?? null,
    createdAt:epoch(volume.created_at),attachedTo:[],
    branches:(volume.branches || []).map(branch=>({name:String(branch.name),origin:branch.origin ?? null,createdAt:epoch(branch.created_at)}))
  }));
});
export const dateLabel = created;
