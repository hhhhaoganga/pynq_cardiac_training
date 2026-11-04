// UI language switch (Chinese default, English lookup table).
#pragma once

#include <atomic>
#include <string>

namespace app {

extern std::atomic<bool> ui_english;
const char *tr(const char *zh);              // translated literal, or zh itself
std::string tr_line(const std::string &line);  // event log line, phrase by phrase

}  // namespace app
