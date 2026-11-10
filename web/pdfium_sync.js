// PDFium for the PDF editor, in the page itself.
//
// pdfrx runs PDFium (a WebAssembly module) in a web worker and only lets the page send it its own commands (open, render, text).
// The editor has to call PDFium's page-object functions, and has to do it synchronously, so it runs a PDFium of its own on the
// page: this loads the same module, with the imports pdfrx's worker script (pdfium_worker.js) defines for it. That script is
// run as a function whose parameters stand in for the worker's globals; it only declares things (the worker waits for a message
// before it starts anything), and the parts of it used here are the module's imports and the table helper.
globalThis.pdfiumSyncLoad = async function (workerScript, wasmBytes) {
  const make = new Function('postMessage', 'onmessage', 'importScripts', 'pdfiumWasmUrl', workerScript + '\n;return { Pdfium, emEnv, wasi };');
  const worker = make(function () {}, null, function () {}, '');
  const result = await WebAssembly.instantiate(wasmBytes, { env: worker.emEnv, wasi_snapshot_preview1: worker.wasi });
  worker.Pdfium.initWith(result.instance.exports);
  result.instance.exports.FPDF_InitLibrary();
  return {
    exports: result.instance.exports,
    addFunction: worker.Pdfium.addFunction,
    removeFunction: worker.Pdfium.removeFunction,
  };
};
