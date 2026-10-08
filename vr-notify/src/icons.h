#pragma once
#include "render.h"

// The image-data hint's (iiibiiay) pixels.
Surface iconFromPixels(int w, int h, int stride, bool alpha, int bitsPerSample, int channels,
                       const std::vector<uint8_t> &data);
// A file path or file:// URI (SVG, or anything gdk-pixbuf reads).
Surface iconFromPath(const std::string &path);
// A path, URI, or icon theme name.
Surface iconFromSpec(const std::string &spec);
// The Icon= of <desktopEntry>.desktop.
Surface iconFromDesktopEntry(const std::string &desktopEntry);
