// The Shortcuts tour: the bottom of a German MacBook keyboard and every voice shortcut, in four
// coloured sections. The step at the reading line lights its keys; the page renders all of it,
// the script only plays it. "slash" is the dictation key: "-" on German keyboards, "/" on US.

/** [id, label, width in keys, sub label or modifier glyph, kind] */
export type KeyDef = [id: string, label: string, width: number, sub?: string, kind?: 'mod' | 'mod r' | 'ret2' | 'dk'];

const letters = (s: string): KeyDef[] => s.split('').map((c) => [c.toLowerCase(), c, 1]);

export const ROWS: KeyDef[][] = [
  [['caps', '⇪', 1.75], ...letters('ASDFGHJKLÖÄ'), ['#', '#', 1, "'"], ['ret2', '', 1.25, '', 'ret2']],
  [['shiftL', 'shift', 1.25, '⇧', 'mod'], ['<', '<', 1, '>'], ...letters('YXCVBNM'), ['comma', ',', 1, ';'], ['period', '.', 1, ':'],
    ['slash', '-', 1, '_', 'dk'], ['shiftR', 'shift', 2.75, '⇧', 'mod r']],
  [['fn', 'fn', 1, '◎', 'mod'], ['ctrl', 'control', 1, '⌃', 'mod'], ['optL', 'option', 1, '⌥', 'mod'], ['cmdL', 'command', 1.25, '⌘', 'mod'],
    ['space', '', 5.5], ['cmdR', 'command', 1.25, '⌘', 'mod r'], ['optR', 'option', 1, '⌥', 'mod r']],
];

export const KEY_NAME: Record<string, string> = {
  optL: '⌥ Option', optR: '⌥ Option', cmdL: '⌘ Command', shiftL: '⇧ Shift', shiftR: '⇧ Shift',
  comma: ',', period: '.', slash: '-', v: 'V',
};

export type How = 'tap' | 'hold' | 'toggle';
export interface Part { keys: string[]; how: How; live?: string; done?: string }
export interface Step { name: string; text: string; parts: Part[] }
export interface Section { id: string; color: string; title: string; key: string[]; blurb: string; steps: Step[] }

export const HOW: Record<How, string> = { tap: 'Tap', hold: 'Hold', toggle: 'Press to start and stop' };

export const SECTIONS: Section[] = [
  { id: 'talk', color: '--dictation', title: 'Dictation', key: ['⌥', 'slash'], blurb: 'Speak, and the text appears where your cursor is.', steps: [
    { name: 'Push to talk', text: 'Hold while you speak. Let go and it is typed.', parts: [{ keys: ['optR', 'slash'], how: 'hold', live: 'Listening', done: 'Typed into your app' }] },
    { name: 'Hands-free', text: 'Press once and talk as long as you like. Press again to stop.', parts: [{ keys: ['shiftR', 'optR', 'slash'], how: 'toggle', live: 'Recording hands-free', done: 'Stopped and typed' }] },
  ] },
  { id: 'smart', color: '--smart', title: 'Smart read', key: ['⌥', ','], blurb: 'Select text first. The AI works on exactly that text and answers out loud.', steps: [
    { name: 'Smart read the selected text', text: 'Select text anywhere, then tap. You hear what it means.', parts: [{ keys: ['optR', 'comma'], how: 'tap', live: 'Thinking about the selected text' }] },
    { name: 'Ask about the selected text', text: 'Select text, then hold the same keys and ask out loud. Let go to get the answer.', parts: [{ keys: ['optR', 'comma'], how: 'hold', live: 'Listening to your question', done: 'Answering out loud' }] },
    { name: 'Smart read the clipboard', text: 'No selection needed: add Shift and it uses what you copied.', parts: [{ keys: ['shiftR', 'optR', 'comma'], how: 'tap', live: 'Thinking about the clipboard' }] },
    { name: 'Ask about the clipboard', text: 'Smart read the clipboard first. Then, with nothing selected, hold and ask.', parts: [
      { keys: ['shiftR', 'optR', 'comma'], how: 'tap', live: 'Thinking about the clipboard' },
      { keys: ['optR', 'comma'], how: 'hold', live: 'Listening to your question', done: 'Answering out loud' }] },
  ] },
  { id: 'read', color: '--read', title: 'Read', key: ['⌥', '.'], blurb: 'Hear any text in a natural voice.', steps: [
    { name: 'Read the selection', text: 'Select text and tap. Tap again to stop.', parts: [{ keys: ['optR', 'period'], how: 'tap', live: 'Reading aloud' }] },
    { name: 'Read the clipboard', text: 'Add Shift to hear what you copied.', parts: [{ keys: ['shiftR', 'optR', 'period'], how: 'tap', live: 'Reading the clipboard' }] },
  ] },
  { id: 'paste', color: '--tools', title: 'Paste again', key: ['⌥', '⌘', 'V'], blurb: 'Put the last result where you need it.', steps: [
    { name: 'Last dictation', text: 'Like ⌘ V with Option added: Option and Command sit side by side.', parts: [{ keys: ['optL', 'cmdL', 'v'], how: 'tap', done: 'Dictation pasted' }] },
    { name: 'Last smart read', text: 'Same, plus Shift.', parts: [{ keys: ['shiftL', 'optL', 'cmdL', 'v'], how: 'tap', done: 'Answer pasted' }] },
  ] },
];

/** Every step in page order, with its section: the script indexes steps by this order. */
export const FLAT = SECTIONS.flatMap((sec) => sec.steps.map((step) => ({ sec, step })));
