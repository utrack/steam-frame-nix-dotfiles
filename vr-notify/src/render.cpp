#include "render.h"

#include <cmath>
#include <pango/pangocairo.h>
#include <regex>

Surface adopt(cairo_surface_t *s) { return Surface(s, cairo_surface_destroy); }

namespace {
constexpr int W = TOAST_W, PAD = 28, ICON = 80, GAP = 22, CLOSE = 46;
constexpr int BTN_H = 62, BTN_GAP = 12, BTN_PER_ROW = 3;

using LayoutPtr = std::unique_ptr<PangoLayout, decltype(&g_object_unref)>;

LayoutPtr text(cairo_t *cr, const char *font, const std::string &markup, int width, int lines) {
  LayoutPtr l(pango_cairo_create_layout(cr), g_object_unref);
  PangoFontDescription *fd = pango_font_description_from_string(font);
  pango_layout_set_font_description(l.get(), fd);
  pango_font_description_free(fd);
  pango_layout_set_width(l.get(), width * PANGO_SCALE);
  pango_layout_set_wrap(l.get(), PANGO_WRAP_WORD_CHAR);
  pango_layout_set_ellipsize(l.get(), PANGO_ELLIPSIZE_END);
  pango_layout_set_height(l.get(), -lines);
  pango_layout_set_markup(l.get(), markup.c_str(), -1);
  return l;
}

int height(const LayoutPtr &l) {
  int w, h;
  pango_layout_get_pixel_size(l.get(), &w, &h);
  return h;
}

void draw(cairo_t *cr, const LayoutPtr &l, double x, double y, double grey, double alpha = 1) {
  cairo_set_source_rgba(cr, grey, grey, grey, alpha);
  cairo_move_to(cr, x, y);
  pango_cairo_show_layout(cr, l.get());
}
} // namespace

int Rendered::hitAt(double x, double y) const {
  for (size_t i = 0; i < hits.size(); i++) {
    const Hit &h = hits[i];
    if (x >= h.x && x < h.x + h.w && y >= h.y && y < h.y + h.h) return int(i);
  }
  return -1;
}

std::string escapeMarkup(const std::string &s) {
  char *e = g_markup_escape_text(s.c_str(), -1);
  std::string out = e;
  g_free(e);
  return out;
}

std::string bodyMarkup(const std::string &body) {
  using std::regex;
  auto f = regex::icase | regex::ECMAScript;
  std::string s = std::regex_replace(body, regex("<img[^>]*>", f), "");
  s = std::regex_replace(s, regex("<a(\\s[^>]*)?>", f), "<u>");
  s = std::regex_replace(s, regex("</a\\s*>", f), "</u>");
  s = std::regex_replace(s, regex("<br\\s*/?>", f), "\n");
  if (pango_parse_markup(s.c_str(), -1, 0, nullptr, nullptr, nullptr, nullptr)) return s;
  return escapeMarkup(body);
}

namespace {
void toRgba(cairo_surface_t *s, Rendered &r) {
  // cairo's native-endian ARGB32 to RGBA bytes, alpha stays premultiplied
  cairo_surface_flush(s);
  const uint8_t *src = cairo_image_surface_get_data(s);
  int stride = cairo_image_surface_get_stride(s);
  r.rgba.resize(size_t(r.w) * r.h * 4);
  for (int y = 0; y < r.h; y++)
    for (int x = 0; x < r.w; x++) {
      uint32_t p = reinterpret_cast<const uint32_t *>(src + y * stride)[x];
      uint8_t *d = &r.rgba[(size_t(y) * r.w + x) * 4];
      d[0] = p >> 16, d[1] = p >> 8, d[2] = p, d[3] = p >> 24;
    }
}
} // namespace

Rendered renderHighlight(const Hit &hit) {
  Rendered r;
  r.w = int(std::lround(hit.w)), r.h = int(std::lround(hit.h));
  Surface s = adopt(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, r.w, r.h));
  cairo_t *cr = cairo_create(s.get());
  cairo_set_source_rgba(cr, 1, 1, 1, 0.16);
  cairo_paint(cr);
  cairo_destroy(cr);
  toRgba(s.get(), r);
  return r;
}

Rendered renderToast(const Content &c) {
  Rendered r;
  r.w = W;
  const int x0 = c.icon ? PAD + ICON + GAP : PAD, tw = W - x0 - PAD;

  // measure on a scratch surface, then draw at the measured height
  Surface scratch = adopt(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1));
  cairo_t *mcr = cairo_create(scratch.get());
  auto app = text(mcr, "Noto Sans 17", c.app, tw - CLOSE, 1);
  auto summary = text(mcr, "Noto Sans Bold 24", c.summary, tw, 2);
  auto body = text(mcr, "Noto Sans 21", c.body, tw, 6);
  int y = PAD, yApp = y;
  y += height(app) + 4;
  int ySummary = y;
  if (!c.summary.empty()) y += height(summary) + 6;
  int yBody = y;
  if (!c.body.empty()) y += height(body);
  int bottom = std::max(y, c.icon ? PAD + ICON : 0);

  const int rows = (int(c.buttons.size()) + BTN_PER_ROW - 1) / BTN_PER_ROW;
  int yButtons = bottom + 20;
  if (rows) bottom = yButtons + rows * BTN_H + (rows - 1) * BTN_GAP;
  r.h = bottom + PAD;

  r.hits.push_back({double(W - PAD - CLOSE + 10), double(PAD - 12), double(CLOSE), double(CLOSE),
                    HitKind::Close, ""});
  for (int row = 0, i = 0; row < rows; row++) {
    int n = std::min(BTN_PER_ROW, int(c.buttons.size()) - row * BTN_PER_ROW);
    double bw = double(W - 2 * PAD - (n - 1) * BTN_GAP) / n;
    for (int k = 0; k < n; k++, i++)
      r.hits.push_back({PAD + k * (bw + BTN_GAP), double(yButtons + row * (BTN_H + BTN_GAP)), bw,
                        double(BTN_H), HitKind::Action, c.buttons[i].key});
  }
  r.hits.push_back({0, 0, double(W), double(r.h), HitKind::Body, ""});
  cairo_destroy(mcr);

  Surface s = adopt(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, r.w, r.h));
  cairo_t *cr = cairo_create(s.get());
  pango_cairo_update_layout(cr, app.get());
  pango_cairo_update_layout(cr, summary.get());
  pango_cairo_update_layout(cr, body.get());

  cairo_set_source_rgb(cr, 0.13, 0.14, 0.16);
  cairo_paint(cr);
  cairo_rectangle(cr, 1, 1, r.w - 2, r.h - 2);
  cairo_set_line_width(cr, 2);
  if (c.critical) cairo_set_source_rgba(cr, 0.93, 0.27, 0.27, 0.9);
  else cairo_set_source_rgba(cr, 1, 1, 1, 0.12);
  cairo_stroke(cr);

  if (c.icon) {
    int iw = cairo_image_surface_get_width(c.icon.get()), ih = cairo_image_surface_get_height(c.icon.get());
    double sc = double(ICON) / std::max(iw, ih);
    cairo_save(cr);
    cairo_rectangle(cr, PAD, PAD, ICON, ICON);
    cairo_clip(cr);
    cairo_translate(cr, PAD + (ICON - iw * sc) / 2, PAD + (ICON - ih * sc) / 2);
    cairo_scale(cr, sc, sc);
    cairo_set_source_surface(cr, c.icon.get(), 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
    cairo_paint(cr);
    cairo_restore(cr);
  }

  draw(cr, app, x0, yApp, 0.68);
  if (!c.summary.empty()) draw(cr, summary, x0, ySummary, 1);
  if (!c.body.empty()) draw(cr, body, x0, yBody, 0.88);

  const Hit &close = r.hits[0];
  double cx = close.x + close.w / 2, cy = close.y + close.h / 2;
  cairo_set_line_width(cr, 3);
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
  cairo_set_source_rgba(cr, 1, 1, 1, 0.7);
  for (int sgn : {-1, 1}) {
    cairo_move_to(cr, cx - 9, cy - 9 * sgn);
    cairo_line_to(cr, cx + 9, cy + 9 * sgn);
  }
  cairo_stroke(cr);

  for (size_t i = 1; i + 1 < r.hits.size(); i++) {
    const Hit &h = r.hits[i];
    cairo_rectangle(cr, h.x, h.y, h.w, h.h);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.11);
    cairo_fill(cr);
    auto label = text(cr, "Noto Sans Medium 19", escapeMarkup(c.buttons[i - 1].label), int(h.w) - 24, 1);
    pango_layout_set_alignment(label.get(), PANGO_ALIGN_CENTER);
    draw(cr, label, h.x + 12, h.y + (h.h - height(label)) / 2, 1);
  }
  cairo_destroy(cr);
  toRgba(s.get(), r);
  return r;
}
