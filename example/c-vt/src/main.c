#include <stddef.h>
#include <ghostty/vt.h>

int main() {
  GhosttyOscParser parser;
  if (ghostty_vt_osc_new(NULL, &parser) != GHOSTTY_VT_SUCCESS) {
    return 1;
  }
  ghostty_vt_osc_free(parser);
  return 0;
}
