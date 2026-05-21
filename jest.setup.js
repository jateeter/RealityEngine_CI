/**
 * Jest setup file to ensure Node.js globals are available in test environment
 */

// Ensure ReadableStream is available globally for undici/Qdrant
if (typeof global.ReadableStream === 'undefined') {
  const { ReadableStream } = await import('stream/web');
  global.ReadableStream = ReadableStream;
}
