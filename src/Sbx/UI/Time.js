import dayjs from 'dayjs';
export const created = seconds => {
  if (seconds == null || !Number.isFinite(seconds)) return 'Unknown';
  const date = dayjs(seconds * 1000);
  return date.isValid() ? date.format('YYYY-MM-DD HH:mm Z') : 'Unknown';
};
export const timestamp = value => {
  if (!value) return '';
  const date = dayjs(String(value).replace(/,(\d+)/, '.$1'));
  return date.isValid() ? date.format('YYYY-MM-DD HH:mm:ss.SSS Z') : 'Unknown';
};
// Keep a precise instant internally; localization happens at presentation time.
export const now = () => dayjs().toISOString();
