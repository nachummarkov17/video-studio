// history.js — undo/redo for the editor (Ctrl+Z, Ctrl+Shift+Z / Ctrl+Y).
//
// Snapshot-based: the whole project is cloned before each action. Projects are
// small (a few hundred clips at most), so this is far simpler and far less
// bug-prone than tracking inverse operations for every edit.
//
// One snapshot per GESTURE: a drag pushes on mousedown, not on every mousemove,
// so a single undo reverses the whole drag rather than one pixel of it.

const DEFAULT_LIMIT = 50;

const clone = (s) => (typeof structuredClone === 'function'
  ? structuredClone(s)
  : JSON.parse(JSON.stringify(s)));

export class History {
  constructor(limit = DEFAULT_LIMIT) {
    this.limit = Math.max(1, limit);
    this._undo = [];
    this._redo = [];
  }

  // Record the state as it is BEFORE the action about to happen.
  push(state) {
    this._undo.push(clone(state));
    if (this._undo.length > this.limit) this._undo.shift();
    this._redo.length = 0;      // a new action invalidates any redo trail
  }

  // Hand back the previous state; `current` is stashed so redo can return to it.
  undo(current) {
    if (!this._undo.length) return null;
    this._redo.push(clone(current));
    return this._undo.pop();
  }

  redo(current) {
    if (!this._redo.length) return null;
    this._undo.push(clone(current));
    return this._redo.pop();
  }

  canUndo() { return this._undo.length > 0; }
  canRedo() { return this._redo.length > 0; }

  clear() { this._undo.length = 0; this._redo.length = 0; }
}
