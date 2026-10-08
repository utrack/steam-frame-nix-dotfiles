#include "icons.h"

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <librsvg/rsvg.h>
#include <map>
#include <regex>

namespace fs = std::filesystem;

namespace {
constexpr int SIZE = 160; // icons are drawn at 80 px

std::vector<std::string> dataDirs() {
  const char *home = getenv("HOME");
  const char *dataHome = getenv("XDG_DATA_HOME");
  std::string h = home ? home : "";
  std::string local = dataHome && *dataHome ? dataHome : h + "/.local/share";
  return {local, local + "/flatpak/exports/share", "/var/lib/flatpak/exports/share",
          h + "/.nix-profile/share", "/usr/local/share", "/usr/share"};
}

// icon name -> file, the dark themes first since the toasts are dark
struct IconIndex {
  std::map<std::string, std::string> files;
  std::chrono::steady_clock::time_point built{};
  bool ready = false;

  static int score(const fs::path &p) {
    if (p.extension() == ".svg") return 100000;
    static const std::regex size("/(\\d+)(x\\d+)?(@\\d+x?)?/");
    std::smatch m;
    std::string s = p.string();
    return std::regex_search(s, m, size) ? std::stoi(m[1]) : 1;
  }

  void build() {
    files.clear();
    for (const char *theme : {"breeze-dark", "breeze", "hicolor", "Adwaita"}) {
      std::map<std::string, std::pair<int, std::string>> best;
      for (const auto &base : dataDirs()) {
        std::error_code ec;
        fs::path dir = fs::path(base) / "icons" / theme;
        if (!fs::is_directory(dir, ec)) continue;
        auto opts = fs::directory_options::skip_permission_denied | fs::directory_options::follow_directory_symlink;
        for (auto it = fs::recursive_directory_iterator(dir, opts, ec); !ec && it != fs::recursive_directory_iterator();
             it.increment(ec)) {
          if (it.depth() > 4) { it.disable_recursion_pending(); continue; }
          const fs::path &p = it->path();
          if (p.extension() != ".svg" && p.extension() != ".png") continue;
          int sc = score(p);
          auto &b = best[p.stem().string()];
          if (sc > b.first) b = {sc, p.string()};
        }
      }
      for (auto &[name, b] : best) files.emplace(name, b.second);
    }
    for (const auto &base : dataDirs()) {
      std::error_code ec;
      for (auto it = fs::directory_iterator(fs::path(base) / "pixmaps", ec); !ec && it != fs::directory_iterator();
           it.increment(ec))
        files.emplace(it->path().stem().string(), it->path().string());
    }
    built = std::chrono::steady_clock::now();
    ready = true;
  }

  std::string find(const std::string &name) {
    if (!ready) build();
    auto it = files.find(name);
    if (it == files.end() && std::chrono::steady_clock::now() - built > std::chrono::minutes(1)) {
      build(); // newly installed apps
      it = files.find(name);
    }
    return it == files.end() ? "" : it->second;
  }
};

IconIndex &index() {
  static IconIndex i;
  return i;
}
} // namespace

Surface iconFromPixels(int w, int h, int stride, bool alpha, int bitsPerSample, int channels,
                       const std::vector<uint8_t> &data) {
  if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || bitsPerSample != 8 || channels != (alpha ? 4 : 3) ||
      stride < w * channels || data.size() < size_t(h - 1) * stride + size_t(w) * channels)
    return nullptr;
  Surface s = adopt(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h));
  cairo_surface_flush(s.get());
  uint8_t *dst = cairo_image_surface_get_data(s.get());
  int ds = cairo_image_surface_get_stride(s.get());
  for (int y = 0; y < h; y++)
    for (int x = 0; x < w; x++) {
      const uint8_t *p = &data[size_t(y) * stride + size_t(x) * channels];
      uint32_t a = alpha ? p[3] : 255;
      reinterpret_cast<uint32_t *>(dst + y * ds)[x] =
          a << 24 | (p[0] * a / 255) << 16 | (p[1] * a / 255) << 8 | (p[2] * a / 255);
    }
  cairo_surface_mark_dirty(s.get());
  return s;
}

Surface iconFromPath(const std::string &spec) {
  std::string path = spec;
  if (spec.rfind("file://", 0) == 0) {
    char *p = g_filename_from_uri(spec.c_str(), nullptr, nullptr);
    if (!p) return nullptr;
    path = p;
    g_free(p);
  }
  GError *err = nullptr;
  fs::path fp(path);
  if (fp.extension() == ".svg" || fp.extension() == ".svgz") {
    RsvgHandle *svg = rsvg_handle_new_from_file(path.c_str(), &err);
    if (!svg) { g_clear_error(&err); return nullptr; }
    Surface s = adopt(cairo_image_surface_create(CAIRO_FORMAT_ARGB32, SIZE, SIZE));
    cairo_t *cr = cairo_create(s.get());
    RsvgRectangle vp{0, 0, SIZE, SIZE};
    bool ok = rsvg_handle_render_document(svg, cr, &vp, &err);
    cairo_destroy(cr);
    g_object_unref(svg);
    g_clear_error(&err);
    return ok ? s : nullptr;
  }
  GdkPixbuf *pb = gdk_pixbuf_new_from_file_at_scale(path.c_str(), SIZE, SIZE, TRUE, &err);
  if (!pb) { g_clear_error(&err); return nullptr; }
  int w = gdk_pixbuf_get_width(pb), h = gdk_pixbuf_get_height(pb), stride = gdk_pixbuf_get_rowstride(pb);
  const guint8 *px = gdk_pixbuf_read_pixels(pb);
  std::vector<uint8_t> data(px, px + size_t(h - 1) * stride +
                                    size_t(w) * gdk_pixbuf_get_n_channels(pb));
  Surface s = iconFromPixels(w, h, stride, gdk_pixbuf_get_has_alpha(pb), gdk_pixbuf_get_bits_per_sample(pb),
                             gdk_pixbuf_get_n_channels(pb), data);
  g_object_unref(pb);
  return s;
}

Surface iconFromSpec(const std::string &spec) {
  if (spec.empty()) return nullptr;
  if (spec[0] == '/' || spec.rfind("file://", 0) == 0) return iconFromPath(spec);
  std::string file = index().find(spec);
  return file.empty() ? nullptr : iconFromPath(file);
}

Surface iconFromDesktopEntry(const std::string &entry) {
  if (entry.empty() || entry.find('/') != std::string::npos) return nullptr;
  for (const auto &base : dataDirs()) {
    std::ifstream f(base + "/applications/" + entry + ".desktop");
    for (std::string line; std::getline(f, line);)
      if (line.rfind("Icon=", 0) == 0) return iconFromSpec(line.substr(5));
  }
  return nullptr;
}
