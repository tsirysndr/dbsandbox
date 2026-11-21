import {now} from '../Sbx.UI.Time/foreign.js';
export const clean = value => String(value).replace(/\x1b\[[0-?]*[ -/]*[@-~]/g,'').replace(/[\x00-\x1f\x7f-\x9f]/g,' ');

export const lastChar = value => Array.from(value).slice(0,-1).join('');

export const timestamp = now;
