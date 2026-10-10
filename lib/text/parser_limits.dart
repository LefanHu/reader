/// Source and archive bounds enforced before untrusted content is expanded.
const maxBookBytes = 100 * 1024 * 1024;

/// Total expanded archive budget, including resources never rendered.
const maxExpandedBytes = 300 * 1024 * 1024;

/// Maximum archive directory size accepted by the importer.
const maxArchiveEntries = 10000;

/// Each normalized section fits the server's chapter payload limits.
const maxSectionCharacters = 400000;

/// Server paragraph limit, measured in UTF-16 code units.
const maxBlockCharacters = 20000;
