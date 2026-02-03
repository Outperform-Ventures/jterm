#!/usr/bin/env nu

use github.nu

# Vouch - contributor trust management.
#
# Environment variables required:
#
#   GITHUB_TOKEN - GitHub API token with repo access. If this isn't
#     set then we'll attempt to read from `gh` if it exists.
export def main [] {
  print "Usage: vouch <command>"
  print ""
  print "Local Commands:"
  print "  add               Add a user to the vouched contributors list"
  print "  check             Check a user's vouch status"
  print "  denounce          Denounce a user by adding them to the vouched file"
  print ""
  print "GitHub integration:"
  print "  gh-check-pr         Check if a PR author is a vouched contributor"
  print "  gh-manage-by-issue  Manage contributor status via issue comment"
}

# Add a user to the vouched contributors list.
#
# This adds the user to the vouched list, removing any existing entry
# (vouched or denounced) for that user first.
#
# Examples:
#
#   # Dry run (default) - see what would happen
#   ./vouch.nu add someuser
#
#   # Actually add the user
#   ./vouch.nu add someuser --dry-run=false
#
export def "main add" [
  username: string,          # GitHub username to vouch for
  --vouched-file: string,    # Path to vouched contributors file (default: VOUCHED or .github/VOUCHED)
  --dry-run = true,          # Print what would happen without making changes
] {
  let file = if ($vouched_file | is-empty) {
    let default = default-vouched-file
    if ($default | is-empty) {
      error make { msg: "no VOUCHED file found" }
    }
    $default
  } else {
    $vouched_file
  }

  if $dry_run {
    print $"(dry-run) Would add ($username) to ($file)"
    return
  }

  let content = open $file
  let lines = $content | lines
  let comments = $lines | where { |line| ($line | str starts-with "#") or ($line | str trim | is-empty) }
  let contributors = $lines
    | where { |line| not (($line | str starts-with "#") or ($line | str trim | is-empty)) }

  let new_contributors = add-user $username $contributors
  let new_content = ($comments | append $new_contributors | str join "\n") + "\n"
  $new_content | save -f $file

  print $"Added ($username) to vouched contributors"
}

# Manage contributor status via issue comments.
#
# This checks if a comment matches "lgtm" (vouch) or "denounce" (denounce),
# verifies the commenter has write access, and updates the vouched list accordingly.
#
# For denounce, the comment can be:
#   - "denounce" - denounces the issue author
#   - "denounce username" - denounces the specified user
#   - "denounce username reason" - denounces with a reason
#
# Outputs a status to stdout: "vouched", "denounced", or "unchanged"
#
# Examples:
#
#   # Dry run (default) - see what would happen
#   ./vouch.nu gh-manage-by-issue 123 456789
#
#   # Actually perform the action
#   ./vouch.nu gh-manage-by-issue 123 456789 --dry-run=false
#
export def "main gh-manage-by-issue" [
  issue_id: int,           # GitHub issue number
  comment_id: int,         # GitHub comment ID
  --repo (-R): string = "ghostty-org/ghostty", # Repository in "owner/repo" format
  --vouched-file: string,  # Path to vouched contributors file (default: VOUCHED or .github/VOUCHED)
  --allow-vouch = true,   # Enable "lgtm" handling to vouch for contributors
  --allow-denounce = true, # Enable "denounce" handling to denounce users
  --dry-run = true,        # Print what would happen without making changes
] {
  let file = if ($vouched_file | is-empty) {
    let default = default-vouched-file
    if ($default | is-empty) {
      error make { msg: "no VOUCHED file found" }
    }
    $default
  } else {
    $vouched_file
  }

  # Fetch issue and comment data from GitHub API
  let owner = ($repo | split row "/" | first)
  let repo_name = ($repo | split row "/" | last)
  let issue_data = github api "get" $"/repos/($owner)/($repo_name)/issues/($issue_id)"
  let comment_data = github api "get" $"/repos/($owner)/($repo_name)/issues/comments/($comment_id)"

  let issue_author = $issue_data.user.login
  let commenter = $comment_data.user.login
  let comment_body = ($comment_data.body | default "" | str trim)

  # Determine action type
  let is_lgtm = $allow_vouch and ($comment_body | parse -r '(?i)^\s*lgtm\b' | is-not-empty)
  let denounce_match = if $allow_denounce {
    $comment_body | parse -r '(?i)^\s*denounce(?:\s+(\S+))?(?:\s+(.+))?$'
  } else {
    []
  }
  let is_denounce = ($denounce_match | is-not-empty)

  if not $is_lgtm and not $is_denounce {
    print "Comment does not match any enabled action"
    print "unchanged"
    return
  }

  # Check if commenter has write access
  let permission = try {
    github api "get" $"/repos/($owner)/($repo_name)/collaborators/($commenter)/permission" | get permission
  } catch {
    print $"($commenter) does not have collaborator access"
    print "unchanged"
    return
  }

  if not ($permission in ["admin", "write"]) {
    print $"($commenter) does not have write access"
    print "unchanged"
    return
  }

  let lines = open-vouched-file $file

  if $is_lgtm {
    let status = check-user $issue_author $lines
    if $status == "vouched" {
      print $"($issue_author) is already vouched"

      if not $dry_run {
        github api "post" $"/repos/($owner)/($repo_name)/issues/($issue_id)/comments" {
          body: $"@($issue_author) is already in the vouched contributors list."
        }
      } else {
        print "(dry-run) Would post 'already vouched' comment"
      }

      print "unchanged"
      return
    }

    if $dry_run {
      print $"(dry-run) Would add ($issue_author) to ($file)"
      print "vouched"
      return
    }

    let new_lines = add-user $issue_author $lines
    let new_content = ($new_lines | str join "\n") + "\n"
    $new_content | save -f $file

    print $"Added ($issue_author) to vouched contributors"
    print "vouched"
    return
  }

  if $is_denounce {
    let match = $denounce_match | first
    let target_user = if ($match.capture0? | default "" | is-empty) {
      $issue_author
    } else {
      $match.capture0
    }
    let reason = $match.capture1? | default ""

    let status = check-user $target_user $lines
    if $status == "denounced" {
      print $"($target_user) is already denounced"
      print "unchanged"
      return
    }

    if $dry_run {
      let entry = if ($reason | is-empty) { $"-($target_user)" } else { $"-($target_user) ($reason)" }
      print $"(dry-run) Would add ($entry) to ($file)"
      print "denounced"
      return
    }

    let new_lines = denounce-user $target_user $reason $lines
    let new_content = ($new_lines | str join "\n") + "\n"
    $new_content | save -f $file

    print $"Denounced ($target_user)"
    print "denounced"
    return
  }
}

# Denounce a user by adding them to the VOUCHED file with a minus prefix.
#
# This removes any existing entry for the user and adds them as denounced.
# An optional reason can be provided which will be added after the username.
#
# Examples:
#
#   # Dry run (default) - see what would happen
#   ./vouch.nu denounce badactor
#
#   # Denounce with a reason
#   ./vouch.nu denounce badactor --reason "Submitted AI slop"
#
#   # Actually denounce the user
#   ./vouch.nu denounce badactor --dry-run=false
#
export def "main denounce" [
  username: string,          # GitHub username to denounce
  --reason: string,          # Optional reason for denouncement
  --vouched-file: string,    # Path to vouched contributors file (default: VOUCHED or .github/VOUCHED)
  --dry-run = true,          # Print what would happen without making changes
] {
  let file = if ($vouched_file | is-empty) {
    let default = default-vouched-file
    if ($default | is-empty) {
      error make { msg: "no VOUCHED file found" }
    }
    $default
  } else {
    $vouched_file
  }

  if $dry_run {
    let entry = if ($reason | is-empty) { $"-($username)" } else { $"-($username) ($reason)" }
    print $"\(dry-run\) Would add ($entry) to ($file)"
    return
  }

  let lines = open-vouched-file $file
  let new_lines = denounce-user $username $reason $lines
  let new_content = ($new_lines | str join "\n") + "\n"
  $new_content | save -f $file

  print $"Denounced ($username)"
}

# Check a user's vouch status.
#
# Checks if a user is vouched or denounced (prefixed with -) in a local VOUCHED file.
#
# Exit codes:
#   0 - vouched
#   1 - denounced  
#   2 - unknown
#
# Examples:
#
#   ./vouch.nu check someuser
#   ./vouch.nu check someuser path/to/VOUCHED
#
export def "main check" [
  username: string,          # GitHub username to check
  vouched_file?: path,       # Path to local vouched contributors file (default: VOUCHED or .github/VOUCHED)
] {
  let lines = try {
    open-vouched-file $vouched_file
  } catch {
    print "error: no VOUCHED file found"
    exit 1
  }

  let status = check-user $username $lines
  print $status
  match $status {
    "vouched" => { exit 0 }
    "denounced" => { exit 1 }
    _ => { exit 2 }
  }
}

# Check if a PR author is a vouched contributor.
#
# Checks if a PR author is a bot, collaborator with write access,
# or in the vouched contributors list. If not vouched and --auto-close is set,
# it closes the PR with a comment explaining the process.
#
# Outputs a status to stdout: "skipped", "vouched", "allowed", or "closed"
#
# Examples:
#
#   # Check if PR author is vouched
#   ./vouch.nu gh-check-pr 123
#
#   # Dry run with auto-close - see what would happen
#   ./vouch.nu gh-check-pr 123 --auto-close
#
#   # Actually close an unvouched PR
#   ./vouch.nu gh-check-pr 123 --auto-close --dry-run=false
#
#   # Allow unvouched users but still block denounced users
#   ./vouch.nu gh-check-pr 123 --require-vouch=false --auto-close
#
export def "main gh-check-pr" [
  pr_number: int,            # GitHub pull request number
  --repo (-R): string = "ghostty-org/ghostty", # Repository in "owner/repo" format
  --vouched-file: string = ".github/VOUCHED", # Path to vouched contributors file
  --require-vouch = true,    # Require users to be vouched; if false, only denounced users are blocked
  --auto-close = false,      # Close unvouched PRs with a comment
  --dry-run = true,          # Print what would happen without making changes
] {
  let owner = ($repo | split row "/" | first)
  let repo_name = ($repo | split row "/" | last)

  # Fetch PR data from GitHub API
  let pr_data = github api "get" $"/repos/($owner)/($repo_name)/pulls/($pr_number)"
  let pr_author = $pr_data.user.login
  let default_branch = $pr_data.base.repo.default_branch

  # Skip bots
  if ($pr_author | str ends-with "[bot]") or ($pr_author == "dependabot[bot]") {
    print $"Skipping bot: ($pr_author)"
    print "skipped"
    return
  }

  # Check if user is a collaborator with write access
  let permission = try {
    github api "get" $"/repos/($owner)/($repo_name)/collaborators/($pr_author)/permission" | get permission
  } catch {
    ""
  }

  if ($permission in ["admin", "write"]) {
    print $"($pr_author) is a collaborator with ($permission) access"
    print "vouched"
    return
  }

  # Fetch vouched contributors list from default branch
  let file_data = github api "get" $"/repos/($owner)/($repo_name)/contents/($vouched_file)?ref=($default_branch)"
  let content = $file_data.content | decode base64 | decode utf-8
  let lines = $content | lines
  let status = check-user $pr_author $lines

  if $status == "vouched" {
    print $"($pr_author) is in the vouched contributors list"
    print "vouched"
    return
  }

  if $status == "denounced" {
    print $"($pr_author) is denounced"

    if not $auto_close {
      print "closed"
      return
    }

    print "Closing PR"

    let message = "This PR has been automatically closed because the author has been denounced."

    if $dry_run {
      print "(dry-run) Would post comment and close PR"
      print "closed"
      return
    }

    github api "post" $"/repos/($owner)/($repo_name)/issues/($pr_number)/comments" {
      body: $message
    }

    github api "patch" $"/repos/($owner)/($repo_name)/pulls/($pr_number)" {
      state: "closed"
    }

    print "closed"
    return
  }

  # Unknown - not vouched
  print $"($pr_author) is not vouched"

  if not $require_vouch {
    print $"($pr_author) is allowed (vouch not required)"
    print "allowed"
    return
  }

  if not $auto_close {
    print "closed"
    return
  }

  print "Closing PR"

  let message = $"Hi @($pr_author), thanks for your interest in contributing!

We ask new contributors to open an issue first before submitting a PR. This helps us discuss the approach and avoid wasted effort.

**Next steps:**
1. Open an issue describing what you want to change and why \(keep it concise, write in your human voice, AI slop will be closed\)
2. Once a maintainer vouches for you with `lgtm`, you'll be added to the vouched contributors list
3. Then you can submit your PR

This PR will be closed automatically. See https://github.com/($owner)/($repo_name)/blob/($default_branch)/CONTRIBUTING.md for more details."

  if $dry_run {
    print "(dry-run) Would post comment and close PR"
    print "closed"
    return
  }

  github api "post" $"/repos/($owner)/($repo_name)/issues/($pr_number)/comments" {
    body: $message
  }

  github api "patch" $"/repos/($owner)/($repo_name)/pulls/($pr_number)" {
    state: "closed"
  }

  print "closed"
}

# Check a user's status in contributor lines.
#
# Filters out comments and blank lines before checking.
# Returns "vouched", "denounced", or "unknown".
export def check-user [username: string, lines: list<string>] {
  let contributors = $lines
    | where { |line| not (($line | str starts-with "#") or ($line | str trim | is-empty)) }

  let username_lower = ($username | str downcase)
  for line in $contributors {
    let handle = ($line | str trim | split row " " | first)
    
    if ($handle | str starts-with "-") {
      let denounced_user = ($handle | str substring 1.. | str downcase)
      if $denounced_user == $username_lower {
        return "denounced"
      }
    } else {
      let vouched_user = ($handle | str downcase)
      if $vouched_user == $username_lower {
        return "vouched"
      }
    }
  }

  "unknown"
}

# Add a user to the contributor lines, removing any existing entry first.
#
# Returns the updated lines with the user added and sorted.
export def add-user [username: string, lines: list<string>] {
  let filtered = remove-user $username $lines
  $filtered | append $username | sort -i
}

# Denounce a user in the contributor lines, removing any existing entry first.
#
# Returns the updated lines with the user added as denounced and sorted.
export def denounce-user [username: string, reason: string, lines: list<string>] {
  let filtered = remove-user $username $lines
  let entry = if ($reason | is-empty) { $"-($username)" } else { $"-($username) ($reason)" }
  $filtered | append $entry | sort -i
}

# Remove a user from the contributor lines (whether vouched or denounced).
# Comments and blank lines are ignored (passed through unchanged).
#
# Returns the filtered lines after removal.
export def remove-user [username: string, lines: list<string>] {
  let username_lower = ($username | str downcase)
  $lines | where { |line|
    # Pass through comments and blank lines
    if ($line | str starts-with "#") or ($line | str trim | is-empty) {
      return true
    }

    let handle = ($line | split row " " | first)
    let normalized = if ($handle | str starts-with "-") {
      $handle | str substring 1.. | str downcase
    } else {
      $handle | str downcase
    }

    $normalized != $username_lower
  }
}

# Find the default VOUCHED file by checking common locations.
#
# Checks for VOUCHED in the current directory first, then .github/VOUCHED.
# Returns null if neither exists.
def default-vouched-file [] {
  if ("VOUCHED" | path exists) {
    "VOUCHED"
  } else if (".github/VOUCHED" | path exists) {
    ".github/VOUCHED"
  } else {
    null
  }
}

# Open a vouched file and return all lines.
def open-vouched-file [vouched_file?: path] {
  let file = if ($vouched_file | is-empty) {
    let default = default-vouched-file
    if ($default | is-empty) {
      error make { msg: "no VOUCHED file found" }
    }
    $default
  } else {
    $vouched_file
  }

  open $file | lines
}
