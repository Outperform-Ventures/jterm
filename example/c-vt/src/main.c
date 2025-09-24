#include <stddef.h>
#include <ghostty-vt.h>

int main() {
  GhosttyOscParser parser;
  ghostty_vt_osc_new(NULL, &parser);
  ghostty_vt_osc_free(parser);
  return 0;
}
