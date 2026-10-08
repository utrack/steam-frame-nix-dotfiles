#pragma once
#include <cairo.h>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

constexpr int TOAST_W = 800; // px

using Surface = std::shared_ptr<cairo_surface_t>;
Surface adopt(cairo_surface_t *s);

struct Action {
  std::string key, label;
};

struct Content {
  std::string app, summary, body; // Pango markup
  Surface icon;
  std::vector<Action> buttons;     // without "default"
  bool critical = false;
};

enum class HitKind { Close, Action, Body };

struct Hit {
  double x, y, w, h;
  HitKind kind;
  std::string key;
};

struct Rendered {
  std::vector<uint8_t> rgba; // premultiplied
  int w = 0, h = 0;
  std::vector<Hit> hits;     // first match wins
  int hitAt(double x, double y) const;
};

Rendered renderToast(const Content &c);
// The hover highlight for a hit, drawn over the toast by a separate overlay, so hovering
// doesn't replace the toast's texture (SteamVR shows nothing for a frame when it does).
Rendered renderHighlight(const Hit &hit);
std::string escapeMarkup(const std::string &text);
// The spec's body markup (b, i, u, a, img) as Pango markup, or escaped text.
std::string bodyMarkup(const std::string &body);
