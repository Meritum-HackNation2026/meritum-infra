/**
 * Per-repo settings of the architecture tests; the other files in this folder are
 * copies of the ones in meritum-frontend, meritum-extension and meritum-mocks.
 *
 * @feature none (infrastructure)
 */
export const settings = {
  /** Folders whose code must carry JSDoc with `@feature` and keep constants in constants.ts. */
  sourceDirs: ['src/', 'tests/'],
  /** Never checked: copies owned by other repos (path prefixes). */
  excluded: [
    // copy of meritum-design-system copy/pl.json
    'copy/',
  ],
  /** Line limit of one file. */
  maxLines: 250,
}
