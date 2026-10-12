/// Maximum UTF-8 JSON size of descriptor and finalized result pages.
const analysisPageMaxBytes = 128 * 1024;

/// Maximum ordered chunk descriptors in one manifest upload page.
const analysisDescriptorPageMaxChunks = 100;

/// Soft primary-window target measured in original UTF-16 code units.
const analysisPrimaryTarget = 6000;

/// Maximum preceding, explicitly non-primary context in UTF-16 code units.
const analysisOverlapMaxUnits = 1000;

/// Hard primary-plus-overlap request limit in UTF-16 code units.
const analysisInputMaxUnits = 8000;
