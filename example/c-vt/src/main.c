#include <stddef.h>
#include <stdio.h>
#include <ghostty/vt.h>

int main() {
  GhosttyOscParser parser;
  if (ghostty_osc_new(NULL, &parser) != GHOSTTY_SUCCESS) {
    return 1;
  }
  
  // Setup change window title command to change the title to "a"
  ghostty_osc_next(parser, '0');
  ghostty_osc_next(parser, ';');
  ghostty_osc_next(parser, 'a');
  
  // End parsing and get command
  GhosttyOscCommand command = ghostty_osc_end(parser, 0);
  
  // Get and print command type
  GhosttyOscCommandType type = ghostty_osc_command_type(command);
  printf("Command type: %d\n", type);
  
  ghostty_osc_free(parser);
  return 0;
}
