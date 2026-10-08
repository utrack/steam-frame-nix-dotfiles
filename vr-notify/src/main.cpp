// vr-notifyd: a desktop notification server (org.freedesktop.Notifications) that shows the
// notifications as clickable SteamVR overlays, fixed in the room where you looked when the
// first one came in. One thread: D-Bus and OpenVR are both polled from the loop in main().
#include "icons.h"
#include "render.h"

#include <openvr.h>
#include <sdbus-c++/sdbus-c++.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <optional>
#include <poll.h>

using Clock = std::chrono::steady_clock;
using Hints = std::map<std::string, sdbus::Variant>;
using ImageData = sdbus::Struct<int32_t, int32_t, int32_t, bool, int32_t, int32_t, std::vector<uint8_t>>;

namespace {
const char *IFACE = "org.freedesktop.Notifications";
volatile std::sig_atomic_t g_quit = 0;

struct Config {
  float widthM = 0.24f;    // toast width
  float distanceM = 1.1f;  // from the head
  float rightDeg = 10;     // the stack's bottom left corner, from where you look
  float downDeg = 20;
  float gapM = 0.008f;     // between stacked toasts
  int timeoutMs = 8000;    // when the sender leaves it to the server
  size_t maxVisible = 4;   // the rest wait for a free spot
};

enum Reason : uint32_t { Expired = 1, Dismissed = 2, ClosedByCall = 3 };

struct Note {
  uint32_t id;
  Content content;
  bool hasDefault = false, resident = false;
  int timeoutMs = 0; // 0: until clicked
  std::optional<Clock::time_point> expires; // counts from when it's first shown
  int slot = -1;     // overlay, while shown
  Rendered tex;
  vr::HmdMatrix34_t pose{};
  int hover = -1, pressed = -1;
  bool hovered = false, dirty = true;
};

template <class T> std::optional<T> hint(const Hints &h, const char *key) {
  auto it = h.find(key);
  if (it == h.end() || !it->second.containsValueOfType<T>()) return std::nullopt;
  return it->second.get<T>();
}

bool vrserverRunning() {
  std::error_code ec;
  for (auto &e : std::filesystem::directory_iterator("/proc", ec)) {
    std::ifstream f(e.path() / "comm");
    std::string comm;
    if (std::getline(f, comm) && comm == "vrserver") return true;
  }
  return false;
}

class Daemon {
public:
  Daemon(Config cfg, sdbus::IConnection &conn) : cfg_(cfg), obj_(sdbus::createObject(conn, sdbus::ObjectPath{"/org/freedesktop/Notifications"})) {
    obj_->addVTable(
            sdbus::registerMethod("Notify").implementedAs(
                [this](const std::string &app, uint32_t replaces, const std::string &icon, const std::string &summary,
                       const std::string &body, const std::vector<std::string> &actions, const Hints &hints,
                       int32_t timeout) { return notify(app, replaces, icon, summary, body, actions, hints, timeout); }),
            sdbus::registerMethod("CloseNotification").implementedAs([this](uint32_t id) { close(id, ClosedByCall); }),
            sdbus::registerMethod("GetCapabilities").implementedAs([] {
              return std::vector<std::string>{"actions", "body", "body-markup", "icon-static"};
            }),
            sdbus::registerMethod("GetServerInformation").implementedAs([] {
              return std::tuple<std::string, std::string, std::string, std::string>{"vr-notifyd", "nix-config", "0.1", "1.2"};
            }),
            sdbus::registerSignal("NotificationClosed").withParameters<uint32_t, uint32_t>(),
            sdbus::registerSignal("ActionInvoked").withParameters<uint32_t, std::string>())
        .forInterface(IFACE);
  }

  ~Daemon() { vrDown(); }

  // How long the loop may sleep. Each wakeup asks SteamVR for events over IPC, which is most
  // of what this costs: fast only while the laser is on a toast (hover feedback), slower
  // while toasts show (SteamVR queues the events meanwhile), and slow otherwise (only
  // SteamVR quitting to notice).
  int pollIntervalMs() const {
    int ms = 1000;
    for (auto &n : notes_)
      if (n.slot >= 0) ms = std::min(ms, n.hovered ? 16 : 100);
    return ms;
  }

  void tick() {
    auto now = Clock::now();
    if (!vrUp_ && now >= nextVrTry_) vrUp();
    if (!vrUp_) return;
    pollVr();
    if (!vrUp_) return;
    if (now >= nextSceneCheck_) updateInteractive(now);
    std::vector<uint32_t> expired;
    for (auto &n : notes_) {
      if (!n.expires) continue;
      if (n.hovered) n.expires = std::max(*n.expires, now + std::chrono::seconds(3));
      else if (now >= *n.expires) expired.push_back(n.id);
    }
    for (uint32_t id : expired) close(id, Expired);
    sync(now);
  }

private:
  uint32_t notify(const std::string &app, uint32_t replaces, const std::string &appIcon, const std::string &summary,
                  const std::string &body, const std::vector<std::string> &actions, const Hints &hints, int32_t timeout) {
    Note n;
    auto display = hint<std::string>(hints, "x-kde-display-appname");
    n.content.app = escapeMarkup(display && !display->empty() ? *display : app.empty() ? "Notification" : app);
    n.content.summary = escapeMarkup(summary);
    n.content.body = bodyMarkup(body);
    for (size_t i = 0; i + 1 < actions.size(); i += 2) {
      if (actions[i] == "default") n.hasDefault = true;
      else n.content.buttons.push_back({actions[i], actions[i + 1]});
    }
    auto urgency = hint<uint8_t>(hints, "urgency");
    n.content.critical = urgency && *urgency == 2;
    n.resident = hint<bool>(hints, "resident").value_or(false);
    n.content.icon = icon(appIcon, hints);
    n.timeoutMs = timeout < 0 ? (n.content.critical ? 0 : cfg_.timeoutMs) : timeout;

    for (auto &old : notes_)
      if (replaces && old.id == replaces) {
        n.id = old.id, n.slot = old.slot;
        if (n.slot >= 0 && n.timeoutMs > 0) n.expires = Clock::now() + std::chrono::milliseconds(n.timeoutMs);
        old = std::move(n);
        layoutDirty_ = true;
        fprintf(stderr, "notification %u replaced (%s)\n", old.id, app.c_str());
        return old.id;
      }
    n.id = nextId_++;
    if (nextId_ == 0) nextId_ = 1;
    fprintf(stderr, "notification %u from %s%s\n", n.id, app.c_str(), vrUp_ ? "" : " (SteamVR isn't running)");
    notes_.push_back(std::move(n));
    uint32_t id = notes_.back().id;
    // without SteamVR nothing is shown or expires: keep the newest
    while (notes_.size() > 50) close(notes_.front().id, Expired);
    return id;
  }

  // image-data, image-path, app_icon, then the desktop entry's icon (the spec's order)
  static Surface pixels(const ImageData &d) {
    using std::get;
    return iconFromPixels(get<0>(d), get<1>(d), get<2>(d), get<3>(d), get<4>(d), get<5>(d), get<6>(d));
  }

  Surface icon(const std::string &appIcon, const Hints &hints) {
    for (const char *k : {"image-data", "image_data"})
      if (auto d = hint<ImageData>(hints, k))
        if (auto s = pixels(*d)) return s;
    for (const char *k : {"image-path", "image_path"})
      if (auto p = hint<std::string>(hints, k))
        if (auto s = iconFromSpec(*p)) return s;
    if (auto s = iconFromSpec(appIcon)) return s;
    if (auto d = hint<ImageData>(hints, "icon_data"))
      if (auto s = pixels(*d)) return s;
    if (auto e = hint<std::string>(hints, "desktop-entry")) return iconFromDesktopEntry(*e);
    return nullptr;
  }

  void close(uint32_t id, Reason reason) {
    for (auto it = notes_.begin(); it != notes_.end(); ++it)
      if (it->id == id) {
        if (it->slot >= 0 && vrUp_) vr::VROverlay()->HideOverlay(slots_[it->slot]);
        notes_.erase(it);
        layoutDirty_ = highlightDirty_ = true;
        obj_->emitSignal("NotificationClosed").onInterface(IFACE).withArguments(id, uint32_t(reason));
        return;
      }
  }

  void activate(uint32_t id, const Hit &hit) {
    auto it = std::find_if(notes_.begin(), notes_.end(), [&](const Note &n) { return n.id == id; });
    if (it == notes_.end()) return;
    std::string key = hit.kind == HitKind::Action ? hit.key : hit.kind == HitKind::Body && it->hasDefault ? "default" : "";
    bool resident = it->resident;
    if (!key.empty()) obj_->emitSignal("ActionInvoked").onInterface(IFACE).withArguments(id, key);
    if (key.empty() || !resident) close(id, Dismissed);
  }

  void vrUp() {
    nextVrTry_ = Clock::now() + std::chrono::seconds(3);
    if (!vrserverRunning()) return; // VR_Init would start SteamVR
    vr::EVRInitError err = vr::VRInitError_None;
    vr::VR_Init(&err, vr::VRApplication_Overlay);
    if (err != vr::VRInitError_None) {
      fprintf(stderr, "VR_Init: %s\n", vr::VR_GetVRInitErrorAsEnglishDescription(err));
      return;
    }
    for (size_t i = 0; i < cfg_.maxVisible; i++) {
      vr::VROverlayHandle_t h;
      std::string key = "nixcfg.vr-notify.toast" + std::to_string(i);
      auto e = vr::VROverlay()->FindOverlay(key.c_str(), &h);
      if (e != vr::VROverlayError_None) e = vr::VROverlay()->CreateOverlay(key.c_str(), "Notification", &h);
      if (e != vr::VROverlayError_None) {
        fprintf(stderr, "CreateOverlay %s: %s\n", key.c_str(), vr::VROverlay()->GetOverlayErrorNameFromEnum(e));
        vr::VR_Shutdown();
        slots_.clear();
        return;
      }
      vr::VROverlay()->SetOverlayWidthInMeters(h, cfg_.widthM);
      vr::VROverlay()->SetOverlayInputMethod(h, vr::VROverlayInputMethod_Mouse);
      vr::VROverlay()->SetOverlayFlag(h, vr::VROverlayFlags_IsPremultiplied, true);
      vr::VROverlay()->SetOverlaySortOrder(h, 100);
      slots_.push_back(h);
    }
    // no input method: the laser goes through it to the toast
    if (vr::VROverlay()->FindOverlay("nixcfg.vr-notify.hover", &highlight_) != vr::VROverlayError_None)
      vr::VROverlay()->CreateOverlay("nixcfg.vr-notify.hover", "Notification highlight", &highlight_);
    vr::VROverlay()->SetOverlayFlag(highlight_, vr::VROverlayFlags_IsPremultiplied, true);
    vr::VROverlay()->SetOverlaySortOrder(highlight_, 101);
    highlightSize_ = {0, 0};
    vrUp_ = true;
    interactive_ = std::nullopt;
    nextSceneCheck_ = {};
    for (auto &n : notes_) n.slot = -1, n.dirty = true;
    fprintf(stderr, "connected to SteamVR\n");
  }

  void vrDown() {
    if (!vrUp_) return;
    vr::VR_Shutdown();
    vrUp_ = false;
    slots_.clear();
    for (auto &n : notes_) n.slot = -1, n.hovered = false, n.hover = n.pressed = -1;
    nextVrTry_ = Clock::now() + std::chrono::seconds(5);
    fprintf(stderr, "disconnected from SteamVR\n");
  }

  // The laser stays on while a toast shows, except in VR games, where it would take the
  // controllers away from the game.
  void updateInteractive(Clock::time_point now) {
    nextSceneCheck_ = now + std::chrono::seconds(1);
    bool want = vr::VRApplications()->GetCurrentSceneProcessId() == 0;
    if (interactive_ == want) return;
    interactive_ = want;
    for (auto h : slots_) vr::VROverlay()->SetOverlayFlag(h, vr::VROverlayFlags_MakeOverlaysInteractiveIfVisible, want);
  }

  void pollVr() {
    vr::VREvent_t ev;
    while (vr::VRSystem()->PollNextEvent(&ev, sizeof ev))
      if (ev.eventType == vr::VREvent_Quit) {
        vr::VRSystem()->AcknowledgeQuit_Exiting();
        vrDown();
        return;
      }
    std::vector<std::pair<uint32_t, Hit>> clicks;
    for (auto &n : notes_) {
      if (n.slot < 0) continue;
      while (vr::VROverlay()->PollNextOverlayEvent(slots_[n.slot], &ev, sizeof ev)) {
        double x = ev.data.mouse.x, y = n.tex.h - ev.data.mouse.y; // events have y up
        switch (ev.eventType) {
        case vr::VREvent_MouseMove: {
          n.hovered = true;
          int h = n.tex.hitAt(x, y);
          if (h != n.hover) n.hover = h, highlightDirty_ = true;
          break;
        }
        case vr::VREvent_FocusLeave:
          n.hovered = false, n.pressed = -1;
          if (n.hover != -1) n.hover = -1, highlightDirty_ = true;
          break;
        case vr::VREvent_MouseButtonDown:
          if (ev.data.mouse.button == vr::VRMouseButton_Left) n.pressed = n.tex.hitAt(x, y);
          break;
        case vr::VREvent_MouseButtonUp:
          if (ev.data.mouse.button == vr::VRMouseButton_Left) {
            int h = n.tex.hitAt(x, y);
            if (h >= 0 && h == n.pressed) clicks.push_back({n.id, n.tex.hits[h]});
            n.pressed = -1;
          }
          break;
        }
      }
    }
    for (auto &[id, hit] : clicks) activate(id, hit);
  }

  // The stack's bottom left corner: below and right of where you look, like a flat screen's
  // notifications in its lower right corner; distanceM from your head, upright and facing it.
  void placeAnchor() {
    using V = std::array<float, 3>;
    auto norm = [](V v) {
      float l = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
      return l < 1e-6f ? v : V{v[0] / l, v[1] / l, v[2] / l};
    };
    auto cross = [](V a, V b) { return V{a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]}; };
    vr::TrackedDevicePose_t hmd;
    vr::VRSystem()->GetDeviceToAbsoluteTrackingPose(vr::TrackingUniverseStanding, 0, &hmd, 1);
    vr::HmdMatrix34_t pose = hmd.mDeviceToAbsoluteTracking;
    if (!hmd.bPoseIsValid) pose = {{{1, 0, 0, 0}, {0, 1, 0, 1.6f}, {0, 0, 1, 0}}};
    const auto &m = pose.m;
    V head{m[0][3], m[1][3], m[2][3]};
    float tr = std::tan(cfg_.rightDeg * float(M_PI) / 180), td = std::tan(cfg_.downDeg * float(M_PI) / 180);
    V dir = norm({-m[0][2] + tr * m[0][0] - td * m[0][1], -m[1][2] + tr * m[1][0] - td * m[1][1],
                  -m[2][2] + tr * m[2][0] - td * m[2][1]});
    V corner{head[0] + dir[0] * cfg_.distanceM, head[1] + dir[1] * cfg_.distanceM, head[2] + dir[2] * cfg_.distanceM};
    V z = norm({-dir[0], -dir[1], -dir[2]}); // towards your head
    V x = norm(cross({0, 1, 0}, z));
    if (std::abs(z[1]) > 0.99f) x = {m[0][0], m[1][0], m[2][0]}; // looking straight up or down
    V y = cross(z, x);
    anchor_ = {{{x[0], y[0], z[0], corner[0]}, {x[1], y[1], z[1], corner[1]}, {x[2], y[2], z[2], corner[2]}}};
  }

  void sync(Clock::time_point now) {
    std::vector<bool> used(slots_.size());
    size_t shown = 0;
    for (auto &n : notes_) if (n.slot >= 0) used[n.slot] = true, shown++;
    for (auto &n : notes_) {
      if (n.slot >= 0) continue;
      auto free = std::find(used.begin(), used.end(), false);
      if (free == used.end()) break; // keeps the order: later ones wait too
      if (shown == 0) placeAnchor();
      n.slot = int(free - used.begin());
      used[n.slot] = true;
      shown++;
      n.dirty = true;
      if (n.timeoutMs > 0 && !n.expires) n.expires = now + std::chrono::milliseconds(n.timeoutMs);
    }
    for (auto &n : notes_) {
      if (n.slot < 0 || !n.dirty) continue;
      int oldH = n.tex.h;
      n.tex = renderToast(n.content);
      highlightDirty_ = true;
      auto h = slots_[n.slot];
      vr::VROverlay()->SetOverlayRaw(h, n.tex.rgba.data(), n.tex.w, n.tex.h, 4);
      vr::HmdVector2_t scale{float(n.tex.w), float(n.tex.h)};
      vr::VROverlay()->SetOverlayMouseScale(h, &scale);
      if (n.tex.h != oldH) layoutDirty_ = true;
      n.dirty = false;
    }
    if (layoutDirty_) {
      layoutDirty_ = false;
      // oldest at the bottom, newer ones above: a new toast doesn't move the others
      float y = 0;
      for (auto &n : notes_) {
        if (n.slot < 0) continue;
        float hM = n.tex.h * mPerPx();
        n.pose = anchor_; // centre: right of and above the corner
        for (int r = 0; r < 3; r++) n.pose.m[r][3] += anchor_.m[r][0] * cfg_.widthM / 2 + anchor_.m[r][1] * (y + hM / 2);
        vr::VROverlay()->SetOverlayTransformAbsolute(slots_[n.slot], vr::TrackingUniverseStanding, &n.pose);
        vr::VROverlay()->ShowOverlay(slots_[n.slot]);
        y += hM + cfg_.gapM;
      }
      for (size_t i = 0; i < slots_.size(); i++)
        if (!used[i]) vr::VROverlay()->HideOverlay(slots_[i]);
    }
    if (highlightDirty_) updateHighlight();
  }

  float mPerPx() const { return cfg_.widthM / TOAST_W; }

  void updateHighlight() {
    highlightDirty_ = false;
    auto it = std::find_if(notes_.begin(), notes_.end(), [](const Note &n) {
      return n.slot >= 0 && n.hover >= 0 && n.tex.hits[n.hover].kind != HitKind::Body;
    });
    if (it == notes_.end()) {
      vr::VROverlay()->HideOverlay(highlight_);
      return;
    }
    const Hit &hit = it->tex.hits[it->hover];
    Rendered hl = renderHighlight(hit);
    if (std::pair{hl.w, hl.h} != highlightSize_) { // buttons in a row share one texture
      vr::VROverlay()->SetOverlayRaw(highlight_, hl.rgba.data(), hl.w, hl.h, 4);
      vr::VROverlay()->SetOverlayWidthInMeters(highlight_, hl.w * mPerPx());
      highlightSize_ = {hl.w, hl.h};
    }
    float k = mPerPx(), dx = float(hit.x + hit.w / 2 - it->tex.w / 2.0) * k,
          dy = float(it->tex.h / 2.0 - hit.y - hit.h / 2) * k, dz = 0.002f;
    vr::HmdMatrix34_t t = it->pose;
    for (int r = 0; r < 3; r++) t.m[r][3] += t.m[r][0] * dx + t.m[r][1] * dy + t.m[r][2] * dz;
    vr::VROverlay()->SetOverlayTransformAbsolute(highlight_, vr::TrackingUniverseStanding, &t);
    vr::VROverlay()->ShowOverlay(highlight_);
  }

  Config cfg_;
  std::unique_ptr<sdbus::IObject> obj_;
  std::vector<Note> notes_;
  uint32_t nextId_ = 1;
  bool vrUp_ = false, layoutDirty_ = false, highlightDirty_ = false;
  std::optional<bool> interactive_;
  std::vector<vr::VROverlayHandle_t> slots_;
  vr::VROverlayHandle_t highlight_ = vr::k_ulOverlayHandleInvalid;
  std::pair<int, int> highlightSize_{0, 0};
  Clock::time_point nextVrTry_{}, nextSceneCheck_{};
  vr::HmdMatrix34_t anchor_{};
};

void usage(const char *argv0) {
  fprintf(stderr,
          "usage: %s [--width M] [--distance M] [--right DEG] [--down DEG] [--timeout MS] [--max N]\n"
          "  --width     toast width in metres (0.24)\n"
          "  --distance  from your head, in metres (1.1)\n"
          "  --right, --down\n"
          "              the toasts' bottom left corner from where you look, in degrees (10, 20)\n"
          "  --timeout   when the app leaves it to the server, in ms (8000)\n"
          "  --max       toasts shown at once (4)\n",
          argv0);
}
} // namespace

int main(int argc, char **argv) {
  Config cfg;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (i + 1 >= argc) { usage(argv[0]); return 2; }
    const char *v = argv[++i];
    if (a == "--width") cfg.widthM = std::stof(v);
    else if (a == "--distance") cfg.distanceM = std::stof(v);
    else if (a == "--right") cfg.rightDeg = std::stof(v);
    else if (a == "--down") cfg.downDeg = std::stof(v);
    else if (a == "--timeout") cfg.timeoutMs = std::stoi(v);
    else if (a == "--max") cfg.maxVisible = std::max(1, std::stoi(v));
    else { usage(argv[0]); return 2; }
  }
  std::signal(SIGTERM, [](int) { g_quit = 1; });
  std::signal(SIGINT, [](int) { g_quit = 1; });

  auto conn = sdbus::createSessionBusConnection();
  Daemon daemon(cfg, *conn);
  bool named = false, warned = false;
  auto nextNameTry = Clock::now();

  while (!g_quit) {
    if (!named && Clock::now() >= nextNameTry) {
      try {
        conn->requestName(sdbus::ServiceName{IFACE});
        named = true;
        fprintf(stderr, "serving %s\n", IFACE);
      } catch (const sdbus::Error &e) {
        if (!warned) fprintf(stderr, "can't own %s yet (%s), retrying\n", IFACE, e.getMessage().c_str());
        warned = true;
        nextNameTry = Clock::now() + std::chrono::seconds(2);
      }
    }
    auto pd = conn->getEventLoopPollData();
    pollfd fds[2] = {{pd.fd, pd.events, 0}, {pd.eventFd, POLLIN, 0}};
    int want = daemon.pollIntervalMs(), t = pd.getPollTimeout();
    poll(fds, 2, t < 0 ? want : std::min(t, want));
    while (conn->processPendingEvent()) {}
    daemon.tick();
  }
  if (named) conn->releaseName(sdbus::ServiceName{IFACE});
}
