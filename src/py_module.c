/*
 * Tiny C shim for reclie.
 *
 * Why this file exists:
 *   `PyModuleDef_HEAD_INIT` is a brace-initializer macro that Zig's
 *   translate-c cannot lower into a Zig expression. Letting the C compiler
 *   expand it here keeps the static module-def initialization correct on
 *   every CPython version, including future ABI tweaks.
 *
 *   This is the *only* code that needs to know the layout of
 *   `PyModuleDef_Base`. Everything else is in Zig.
 *
 * Stable ABI: targets CPython >= 3.11 via Py_LIMITED_API.
 */

#define PY_SSIZE_T_CLEAN
#define Py_LIMITED_API 0x030B0000
#include <Python.h>

/* Sentinel-terminated PyMethodDef table — defined in Zig. */
extern PyMethodDef reclie_module_methods[];

static struct PyModuleDef reclie_module_def = {
    PyModuleDef_HEAD_INIT,
    "_reclie",                                      /* m_name */
    "reclie native engine: HTTP, SSE, WebSocket.",  /* m_doc */
    -1,                                             /* m_size: single-phase init */
    reclie_module_methods,                          /* m_methods */
    NULL,                                           /* m_slots */
    NULL,                                           /* m_traverse */
    NULL,                                           /* m_clear */
    NULL,                                           /* m_free */
};

/*
 * CPython looks up `PyInit__reclie` in the loaded shared library — the
 * symbol name must match the file name (`_reclie<ext-suffix>`). We export
 * it from C so the visibility/calling-convention plumbing matches whatever
 * CPython's headers declare on this platform.
 */
PyMODINIT_FUNC PyInit__reclie(void) {
    return PyModule_Create(&reclie_module_def);
}
