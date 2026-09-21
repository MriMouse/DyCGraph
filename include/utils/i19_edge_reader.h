#pragma once
#include <cstdint>
#include <cstdio>
#include <stdexcept>
struct Reader {
  FILE *f;
  explicit Reader(const char *p) : f(fopen(p, "rb")) {
    if (!f)
      throw std::runtime_error(p);
    setvbuf(f, nullptr, _IOFBF, 8 << 20);
  }
  ~Reader() { fclose(f); }
  bool edge(uint32_t &a, uint32_t &b) {
    int c;
    do {
      c = getc_unlocked(f);
      if (c == '#' || c == '%') {
        while (c != EOF && c != '\n')
          c = getc_unlocked(f);
      }
    } while (c != EOF && c <= 32);
    if (c == EOF) {
      if (ferror(f))
        throw std::runtime_error("read error");
      return false;
    }
    auto number = [&]() {
      uint64_t n = 0;
      if (c < '0' || c > '9')
        throw std::runtime_error("invalid edge");
      while (c >= '0' && c <= '9') {
        n = n * 10 + c - '0';
        if (n > UINT32_MAX)
          throw std::runtime_error("ID overflow");
        c = getc_unlocked(f);
      }
      return uint32_t(n);
    };
    a = number();
    while (c == ' ' || c == '\t')
      c = getc_unlocked(f);
    b = number();
    while (c != EOF && c != '\n') {
      if (c > 32)
        throw std::runtime_error("expected unweighted pair");
      c = getc_unlocked(f);
    }
    return true;
  }
};
