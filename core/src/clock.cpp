// NTP-style clock sync over UDP. Host = server (its clock is "master time").
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <ctime>

#include "core.h"

#if defined(__APPLE__)
#include <time.h>
#endif

namespace duet {

int64_t nowNs() {
#if defined(__APPLE__)
  // Same base as mach_absolute_time / AudioTimeStamp.mHostTime.
  return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#else
  timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);  // same base as AAudio timestamps
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
#endif
}

namespace {
constexpr uint32_t kMagic = 0x44554554;  // 'DUET'
struct Ping { uint32_t magic, seq; int64_t t1; };
struct Pong { uint32_t magic, seq; int64_t t1, t2, t3; };
constexpr int64_t kWindowNs = 20'000'000'000LL;  // regression window
}  // namespace

ClockSync& ClockSync::get() {
  static ClockSync c;
  return c;
}

void ClockSync::stop() {
  running_ = false;
  if (sock_ >= 0) { shutdown(sock_, SHUT_RDWR); close(sock_); }
  if (t1_.joinable()) t1_.join();
  if (t2_.joinable()) t2_.join();
  sock_ = -1;
  isMaster_ = true;
  std::lock_guard<std::mutex> l(mu_);
  samples_.clear();
  locked_ = false;
  bestRtt_ = 0;
  nUsed_ = 0;
  model_.store(ClockModel{0, 0, 0});
}

bool ClockSync::startServer(int port) {
  stop();
  sock_ = socket(AF_INET, SOCK_DGRAM, 0);
  if (sock_ < 0) return false;
  int one = 1;
  setsockopt(sock_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  sockaddr_in a{};
  a.sin_family = AF_INET;
  a.sin_port = htons((uint16_t)port);
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(sock_, (sockaddr*)&a, sizeof(a)) != 0) { close(sock_); sock_ = -1; return false; }
  timeval tv{0, 200000};
  setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  isMaster_ = true;
  locked_ = true;
  running_ = true;
  t1_ = std::thread(&ClockSync::serverLoop, this);
  return true;
}

void ClockSync::serverLoop() {
  uint8_t buf[64];
  while (running_) {
    sockaddr_storage from{};
    socklen_t fl = sizeof(from);
    ssize_t n = recvfrom(sock_, buf, sizeof(buf), 0, (sockaddr*)&from, &fl);
    int64_t t2 = nowNs();
    if (n != (ssize_t)sizeof(Ping)) continue;
    Ping p;
    memcpy(&p, buf, sizeof(p));
    if (p.magic != kMagic) continue;
    Pong r{kMagic, p.seq, p.t1, t2, 0};
    r.t3 = nowNs();
    sendto(sock_, &r, sizeof(r), 0, (sockaddr*)&from, fl);
  }
}

bool ClockSync::startClient(const std::string& ip, int port) {
  stop();
  addrinfo hints{}, *res = nullptr;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  std::string ps = std::to_string(port);
  if (getaddrinfo(ip.c_str(), ps.c_str(), &hints, &res) != 0 || !res) return false;
  sock_ = socket(res->ai_family, SOCK_DGRAM, 0);
  if (sock_ < 0) { freeaddrinfo(res); return false; }
  if (connect(sock_, res->ai_addr, res->ai_addrlen) != 0) {
    freeaddrinfo(res); close(sock_); sock_ = -1; return false;
  }
  freeaddrinfo(res);
  timeval tv{0, 200000};
  setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  isMaster_ = false;
  running_ = true;
  startedAt_ = nowNs();
  t1_ = std::thread(&ClockSync::clientSendLoop, this);
  t2_ = std::thread(&ClockSync::clientRecvLoop, this);
  return true;
}

void ClockSync::clientSendLoop() {
  uint32_t seq = 0;
  while (running_) {
    Ping p{kMagic, seq++, nowNs()};
    send(sock_, &p, sizeof(p), 0);
    // 20 Hz burst for the first 3 s, then 10 Hz (also keeps Wi-Fi awake).
    bool burst = nowNs() - startedAt_ < 3'000'000'000LL;
    std::this_thread::sleep_for(std::chrono::milliseconds(burst ? 50 : 100));
  }
}

void ClockSync::clientRecvLoop() {
  uint8_t buf[64];
  while (running_) {
    ssize_t n = recv(sock_, buf, sizeof(buf), 0);
    int64_t t4 = nowNs();
    if (n != (ssize_t)sizeof(Pong)) continue;
    Pong r;
    memcpy(&r, buf, sizeof(r));
    if (r.magic != kMagic) continue;
    int64_t rtt = (t4 - r.t1) - (r.t3 - r.t2);
    if (rtt < 0 || rtt > 2'000'000'000LL) continue;
    int64_t offset = ((r.t2 - r.t1) + (r.t3 - t4)) / 2;
    addSample({r.t1 + (t4 - r.t1) / 2, offset, rtt});
  }
}

void ClockSync::addSample(const Sample& s) {
  std::lock_guard<std::mutex> l(mu_);
  samples_.push_back(s);
  // Drop samples older than the window.
  int64_t cutoff = s.mid - kWindowNs;
  size_t drop = 0;
  while (drop < samples_.size() && samples_[drop].mid < cutoff) drop++;
  if (drop) samples_.erase(samples_.begin(), samples_.begin() + drop);
  if (samples_.size() < 3) return;

  // Keep the fastest 30% round trips: they have the least queueing asymmetry.
  std::vector<int64_t> rtts;
  rtts.reserve(samples_.size());
  for (auto& x : samples_) rtts.push_back(x.rtt);
  std::sort(rtts.begin(), rtts.end());
  bestRtt_ = rtts[0];
  int64_t thr = rtts[std::min(rtts.size() - 1, std::max<size_t>(2, rtts.size() * 3 / 10))];
  std::vector<const Sample*> use;
  for (auto& x : samples_)
    if (x.rtt <= thr) use.push_back(&x);
  nUsed_ = (int)use.size();

  ClockModel m{};
  m.refLocal = s.mid;
  double span = (double)(use.back()->mid - use.front()->mid);
  if (use.size() >= 8 && span > 5e9) {
    // Least squares: offset = a + b*(mid - ref)
    double sx = 0, sy = 0, sxx = 0, sxy = 0, n = (double)use.size();
    int64_t y0 = use.back()->offset;
    for (auto* x : use) {
      double dx = (double)(x->mid - m.refLocal);
      double dy = (double)(x->offset - y0);
      sx += dx; sy += dy; sxx += dx * dx; sxy += dx * dy;
    }
    double den = n * sxx - sx * sx;
    double b = den != 0 ? (n * sxy - sx * sy) / den : 0;
    b = std::max(-200e-6, std::min(200e-6, b));  // phones drift < 200 ppm
    double a = (sy - b * sx) / n;
    m.offset = y0 + (int64_t)a;
    m.skew = b;
  } else {
    // Not enough history yet: median of filtered offsets.
    std::vector<int64_t> o;
    for (auto* x : use) o.push_back(x->offset);
    std::nth_element(o.begin(), o.begin() + o.size() / 2, o.end());
    m.offset = o[o.size() / 2];
    m.skew = 0;
  }
  model_.store(m);
  locked_ = samples_.size() >= 15;
}

void ClockSync::stats(int64_t* out) {
  std::lock_guard<std::mutex> l(mu_);
  ClockModel m = model_.load();
  out[0] = isMaster_ ? 0 : m.offset;
  out[1] = isMaster_ ? 0 : bestRtt_;
  out[2] = isMaster_ ? 0 : (int64_t)(m.skew * 1e9);
  out[3] = isMaster_ ? 0 : nUsed_;
  out[4] = (isMaster_ || locked_) ? 1 : 0;
}

}  // namespace duet
