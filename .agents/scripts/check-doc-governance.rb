#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "set"

ROOT = Pathname.new(__dir__).parent.expand_path
STRICT = ENV["DOC_GOVERNANCE_STRICT"] == "1" || ARGV.include?("--strict")

ID_PATTERN = /(?<![A-Za-z0-9_])(?:Q|DEC|ADR|REQ|NFR|AC|TEST|SPIKE|TASK|TRACE|ASM)-\d{3,4}(?![A-Za-z0-9_#-])/
AC_ID_PATTERN = /(?<![A-Za-z0-9_])AC-\d{3,4}(?![A-Za-z0-9_#-])/
REFERENCE_LINK_DEFINITION_PATTERN = /^\s{0,3}\[([^\]]+)\]:\s*(<[^>]+>|\S+)/
PLACEHOLDER_PATTERNS = [
  /\b(?:Q|DEC|ADR|REQ|NFR|AC|TEST|SPIKE|TASK|TRACE|ASM)-(?:###|####)(?![A-Za-z0-9_#-])/,
  /^\s{0,3}#+\s+(?:Q|DEC|ADR|REQ|NFR|AC|TEST|SPIKE|TASK|TRACE|ASM)-\d{3,4}:\s*(?:\.{3}|…)\s*$/,
  /<(?:질문 한 줄|결정 한 줄|한 줄 제목|이름|Milestone name|YYYY-MM-DD)>/,
  /(?:Opened:|proposed —)\s*<date>/,
  /^\s*Status:\s*template\.\s*$/i
].freeze

# High-confidence merge-time drift markers. These run in default mode (not just
# STRICT) because they catch active-doc residue from in-flight PR work that
# survived merge — `pending Cycle 9 code commit on branch claude/foo`, header
# tokens like `pending merge SHA`, or `Last verified against code:` lines that
# still point at a working branch. Patterns are intentionally narrow: generic
# `pending` / `TBD` prose is NOT matched, so roadmap statements like
# `pending external vendor decision` in `docs/04_IMPLEMENTATION_PLAN.md`
# remain legal.
#
# Branch-shaped fragment: `<identifier>/<path>`. Used generically (not a fixed
# whitelist) so `codex/...`, `bugfix/...`, `dependabot/npm/...`, and any other
# convention is caught alongside the original `claude/` case.
BRANCH_PATH_FRAGMENT = "[A-Za-z][\\w-]*\\/[\\w.\\/-]+"
MERGE_TIME_DRIFT_PATTERNS = [
  /^\s{0,3}>?\s*Last verified against code:.*\bpending\b/i,
  /^\s{0,3}>?\s*Last verified against code:.*\bon\s+branch\b/i,
  # SHA-position branch-shaped token before the date paren — covers any
  # branch-name convention, not just a hardcoded prefix list.
  /^\s{0,3}>?\s*Last verified against code:[^(]*?\b#{BRANCH_PATH_FRAGMENT}/i,
  # `pending Cycle <N> ... on branch <anything>`: the `pending Cycle <N>`
  # prefix is specific enough that any branch token (slashed or word-only)
  # after `on branch` is safe to flag.
  /\bpending\s+Cycle\s+\d+.*\bon\s+branch\s+`?[A-Za-z][\w.\/-]+/i,
  /\bpending\s+merge\s+SHA\b/i
].freeze

# Subset of active docs where merge-time drift markers must never appear.
# Other active docs (PRD, HLD, retrospective, etc.) can legitimately discuss
# in-flight branches in prose; this check stays narrow on purpose.
MERGE_TIME_CHECK_PREFIXES = [
  "docs/current/",
  "docs/context/current-state.md",
  "docs/04_IMPLEMENTATION_PLAN.md"
].freeze

# SHA freshness header check (PR-2). The convention defined in
# docs/DOCUMENTATION.md "SHA freshness headers" is:
#
#     > Last verified against code: <commit-SHA> (<YYYY-MM-DD>)
#
# This check enforces that <commit-SHA> is a 7-40 hex token AND resolves to
# a commit in the local git checkout (PR-mode contract: token must be
# reachable from the PR branch HEAD while the PR is open). Reachability to
# the eventual main SHA after squash merge is intentionally out of scope —
# that's a separate post-merge tripwire.
#
# The header line is captured by anchoring on `Last verified against code:`
# and reading the first non-whitespace, non-paren chunk as the token.
# Trailing punctuation like `,` is stripped to tolerate
# `<sha>, on branch ...` shapes (which PR-1 already flags for the branch
# marker — this check still emits its own format/existence diagnostic).
SHA_HEADER_LINE_PATTERN = /^\s{0,3}>?\s*Last verified against code:\s*(\S+)/i
SHA_TOKEN_FORMAT = /\A[0-9a-f]{7,40}\z/i
# PR-E: the documented header shape is
# `Last verified against code: <commit-SHA> (<YYYY-MM-DD>)`. Once an
# author opts into the header at all, the date suffix is part of the
# contract — without it the "verified against code at this point in
# time" claim is incomplete. The check looks for a parenthesised
# `YYYY-MM-DD` token anywhere on the same line. The trailing content
# inside the parens is unconstrained (so `(2026-05-17, prepared by
# alxdr3k)` is accepted) but the closing `)` is required — a
# truncated `<sha> (2026-05-17` is not a valid suffix (codex P2 on
# PR-E). Missing or malformed date → default error.
SHA_HEADER_DATE_PATTERN = /\(\s*\d{4}-\d{2}-\d{2}[^)]*\)/

# Shallow-clone detection. Use `git rev-parse --is-shallow-repository`
# rather than `ROOT/.git/shallow` because linked worktrees keep `.git`
# as a file (gitdir pointer), so the path-based check would always
# return false in a worktree even when the underlying repo is shallow.
def shallow_repo?
  output = IO.popen(["git", "-C", ROOT.to_s, "rev-parse", "--is-shallow-repository"],
                    err: File::NULL, &:read)
  return false unless $?.success?

  output.strip == "true"
end

# Three-state policy (PR-A hardening):
#
# - DOC_GOVERNANCE_SKIP_SHA_VERIFY=1 → EXPLICIT WAIVER. Skip existence and
#   ancestry checks. Always emit a diagnostic so the operator sees the
#   waiver in CI logs; never silent.
# - Shallow repo without explicit waiver → ENFORCEMENT GAP. Refuse to
#   silently skip: if any `Last verified against code:` header is present
#   in scope, emit a hard error directing the operator to either fetch
#   full history (`fetch-depth: 0`) or set the explicit waiver. A repo
#   that ships no SHA headers stays silent — there is nothing to verify.
# - Full history → run existence + ancestry as usual.
#
# Previously the script collapsed shallow and explicit-waiver into one
# silent skip path, which meant CI runs on GitHub Actions' default
# `actions/checkout@v4` (depth=1) disabled PR-2's core checks without
# operator awareness.
SHALLOW_CLONE = shallow_repo?
EXPLICIT_SKIP_SHA_VERIFY = ENV["DOC_GOVERNANCE_SKIP_SHA_VERIFY"] == "1"
SKIP_SHA_VERIFY = EXPLICIT_SKIP_SHA_VERIFY

# Pending reaping check (PR-3). Convention: every item under a `## Pending`
# section in scoped docs carries explicit `[pending-anchor: <id>]` metadata.
# The check looks each anchor up against the slice-status table in
# `docs/04_IMPLEMENTATION_PLAN.md` and warns if the anchor is already
# `landed`, `accepted`, or `dropped` — the Pending list is stale and the
# item should be removed, moved to Closed, or annotated.
#
# Anchor-less Pending prose is intentionally NOT flagged here: that would
# create noise on every legacy Pending bullet and force a flag day. The
# convention is opt-in per repo (declared in docs/DOCUMENTATION.md). Repos
# that adopt it will see drift; repos that don't will see nothing.
#
# Default mode emits these as warnings (exit 0 if no other errors); STRICT
# mode promotes them to errors. The IMPL_PLAN path can be overridden via
# `DOC_GOVERNANCE_IMPL_PLAN` for adopters whose ledger lives elsewhere; an
# empty value or a path that does not exist disables the check entirely.
PENDING_HEADING_PATTERN = /\A\s{0,3}[#]{1,6}\s+Pending(?:\s+(?:items?|backlog))?\s*[#]*\s*\z/i
# PR-B contract: closed-section headings nested under `## Pending`
# (e.g. `### Closed`, `### Done`, `### Resolved`, `### Reaped`,
# `### Completed`) silence the reaping check for the bullets under
# them. The pattern is intentionally end-open so common decorations
# like `### Closed:`, `### Closed (2026-05-17)`, or `### Done — last
# sprint` all qualify; the author who used a Closed-family keyword
# meant for the suppression to apply.
CLOSED_SUBSECTION_HEADING_PATTERN = /\A\s{0,3}[#]{1,6}\s+(?:Closed|Done|Resolved|Reaped|Completed)\b/i
PENDING_ANCHOR_PATTERN = /\[pending-anchor:\s*([^\]]+?)\s*\]/i
# PR-B contract: `closed by <anchor>` on the same line as a Pending
# anchor silences the warning when the closed-by target equals the
# pending-anchor target. Annotation form: `[pending-anchor: X] …,
# closed by X` (or backtick-wrapped). Mismatched closed-by targets do
# NOT suppress — they still drift.
CLOSED_BY_PATTERN = /\bclosed\s+by\s+`?([A-Za-z][\w.-]*)/i
# PR-B addition: slice-looking anchors that don't resolve in
# IMPL_PLAN.md generate a separate "unknown" warning. Catches typos
# like `EX-1A.33` vs `EX-1A.3`. End-anchored on purpose so adjacent
# namespaces that share a slice-id prefix (e.g. `EX-1A.1-extra`,
# `INFRA-1B.3.h3-audit-hardening`) stay silent — those belong to
# different identifier conventions and should follow the unknown-
# namespace policy from PR-3.
SLICE_LIKE_ANCHOR_PATTERN = /\A[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*\.\d+\z/
ANY_HEADING_PATTERN = /\A\s{0,3}[#]{1,6}\s/
IMPL_PLAN_PATH = ENV.fetch("DOC_GOVERNANCE_IMPL_PLAN", "docs/04_IMPLEMENTATION_PLAN.md")
REAPED_STATUSES = %w[landed accepted dropped].freeze

# Counted-state advisory (PR-4). Adopters declare counted nouns in
# `docs/governance/counted_state.yaml` (or the path in
# `DOC_GOVERNANCE_COUNTED_STATE`); the check scans designated docs for
# numeric mentions of those terms and warns when a line's count
# disagrees with the declared value. Historical statements ARE allowed
# via a qualifier whitelist (`pre-`, `before PR/Cycle/round`, `as of
# <date>`, `historical`, `legacy`, `previous baseline`, `former
# baseline`) so prose like "pre-Cycle-7 12-slice sequence (now 15)"
# stays silent.
#
# The check is opt-in: a missing config file is a no-op. Warnings flow
# through the same channel as Pending reaping (default exit 0; STRICT
# mode promotes to errors). Only the "digit before term" shape is
# matched in this version — schema-version-style `v9` placements are
# out of scope. Adopters who need a different shape can add a thin
# pre-validator on top.
COUNTED_STATE_PATH = ENV.fetch("DOC_GOVERNANCE_COUNTED_STATE", "docs/governance/counted_state.yaml")
HISTORICAL_QUALIFIERS = [
  /\bpre-[A-Za-z0-9]/i,
  /\bbefore\s+(?:PR|Cycle|round|sprint|release)\s*#?\s*\d/i,
  /\bas\s+of\s+\d{4}-\d{2}-\d{2}\b/i,
  /\bhistorical(?:ly)?\b/i,
  # `legacy` standalone was too broad (PR-C codex review). Require
  # the `<baseline|count|value|total>` complement so the qualifier is
  # unambiguous and prose like `legacy adapter path` no longer
  # silences an unrelated drift mention on the same line.
  /\b(?:previous|former|prior|legacy)\s+(?:baseline|count|value|total)\b/i
].freeze
# Clause boundaries used by the match-local qualifier scan. The window
# in front of a count match is narrowed to the text after the most
# recent boundary character, so `previous baseline was 5 axes` on one
# side of a `;` does not silence a `6 axes` drift on the other side.
#
# `.` and `:` are intentionally NOT boundaries. Adding `.` broke
# qualifier scope across version numbers (`legacy baseline v1.2 had
# 6 axes`); adding `:` broke label-style prose (`Previous baseline:
# 6 axes`). Codex PR-C review caught both as regressions from the
# prior line-wide policy. The remaining set keeps the multi-clause
# coverage GPT's review wanted (`6 axes; 5 axes`) without those
# false-positive paths.
COUNTED_STATE_CLAUSE_BOUNDARY = /[;—–]/
COUNTED_STATE_QUALIFIER_WINDOW = 80

EXCLUDED_ACTIVE_PREFIXES = [
  "docs/templates/",
  "docs/discovery/",
  "docs/design/archive/",
  "docs/_examples/",
  "docs/_generated/",
  "docs/generated/"
].freeze

COMPACT_FIRST_READ_DOCS = [
  "AGENTS.md",
  "docs/context/current-state.md",
  "docs/04_IMPLEMENTATION_PLAN.md",
  "docs/current/CODE_MAP.md",
  "docs/current/TESTING.md"
].freeze
MAX_COMPACT_LINE_CHARS = 200
MAX_COMPACT_PARAGRAPH_BYTES = 4 * 1024
MAX_THIN_DOC_EDIT_MARKER_ENTRIES = 10

Definition = Struct.new(:id, :path, :line, keyword_init: true)
Reference = Struct.new(:id, :path, :line, keyword_init: true)

def relative(path)
  Pathname.new(path).expand_path.relative_path_from(ROOT).to_s
end

def active_doc?(path)
  rel = relative(path)
  return false unless rel.end_with?(".md")
  return false if rel.start_with?(".git/")

  EXCLUDED_ACTIVE_PREFIXES.none? { |prefix| rel.start_with?(prefix) }
end

def markdown_files
  tracked = IO.popen(["git", "-C", ROOT.to_s, "ls-files", "-z"], &:read)
  tracked_files = tracked.split("\0").select { |path| path.end_with?(".md") }
  return tracked_files.sort.map { |path| ROOT.join(path) } unless tracked_files.empty?

  Dir.glob(ROOT.join("**/*.md"), File::FNM_DOTMATCH).sort.map { |path| Pathname.new(path) }
end

def reject_symlinked_markdown(files)
  files.each_with_object([]) do |path, errors|
    next unless path.symlink?

    errors << "#{relative(path)} is a symlinked Markdown file; replace it with a regular file before running governance checks"
  end
end

def content_lines(path)
  fence = nil
  html_comment = false
  path.readlines(chomp: true).each_with_index do |line, index|
    if fence
      if (info = fence_marker(line, allow_blockquote: fence[:quote_depth].positive?))
        marker = info[:marker]
        marker_char = marker[0]
        if info[:quote_depth] == fence[:quote_depth] &&
            marker_char == fence[:char] &&
            marker.length >= fence[:length] &&
            info[:trailing].strip.empty?
          fence = nil
        end
      end
      next
    end

    unless html_comment
      if (info = fence_marker(line))
        marker = info[:marker]
        fence = { char: marker[0], length: marker.length, quote_depth: info[:quote_depth] }
        next
      end
      next if indented_code_line?(line)
    end

    line, html_comment = without_html_comments(line, html_comment)
    if (info = fence_marker(line))
      marker = info[:marker]
      fence = { char: marker[0], length: marker.length, quote_depth: info[:quote_depth] }
      next
    end
    next if indented_code_line?(line)

    yield line, index + 1
  end
end

def fence_marker(line, allow_blockquote: true)
  quote_depth, content = allow_blockquote ? blockquote_depth_and_content(line) : [0, line]
  match = content.match(/\A {0,3}(`{3,}|~{3,})(.*)\z/)
  return nil unless match

  { marker: match[1], quote_depth: quote_depth, trailing: match[2] }
end

def blockquote_depth_and_content(line)
  content = line
  depth = 0
  loop do
    stripped = content.sub(/\A {0,3}>\s?/, "")
    return [depth, content] if stripped == content

    content = stripped
    depth += 1
  end
end

def without_html_comments(line, in_comment)
  rendered = +""
  index = 0

  while index < line.length
    if in_comment
      closing = line.index("-->", index)
      return [rendered, true] unless closing

      in_comment = false
      index = closing + 3
      next
    end

    opening = line.index("<!--", index)
    unless opening
      rendered << line[index..]
      break
    end

    rendered << line[index...opening]
    closing = line.index("-->", opening + 4)
    return [rendered, true] unless closing

    index = closing + 3
  end

  [rendered, in_comment]
end

def indented_code_line?(line)
  return false unless line.match?(/^(?: {4}|\t)/)

  !line.match?(/^(?: {4}|\t)\s*(?:[-*+]\s+|\d+[.)]\s+|>\s*|\|)/)
end

def inline_code_text(line, preserve_single: false)
  rendered = +""
  index = 0

  while index < line.length
    unless line[index] == "`"
      rendered << line[index]
      index += 1
      next
    end

    tick_end = index
    tick_end += 1 while tick_end < line.length && line[tick_end] == "`"
    delimiter = "`" * (tick_end - index)
    closing = line.index(delimiter, tick_end)

    unless closing
      rendered << delimiter
      index = tick_end
      next
    end

    rendered << line[tick_end...closing] if preserve_single && delimiter.length == 1
    index = closing + delimiter.length
  end

  rendered
end

def reference_code_text(line)
  # Single-backtick IDs are common live references; multi-backtick spans are
  # treated as literal examples.
  inline_code_text(line, preserve_single: true)
end

def rendered_inline_links(line)
  rendered = +""
  index = 0

  while (marker = line.index("](", index))
    label_start = line.rindex("[", marker)
    unless label_start && label_start >= index
      rendered << line[index, marker + 2 - index]
      index = marker + 2
      next
    end

    image = label_start.positive? && line[label_start - 1] == "!"
    link_start = image ? label_start - 1 : label_start
    depth = 0
    position = marker + 2

    while position < line.length
      char = line[position]
      if char == "\\" && position + 1 < line.length
        position += 2
        next
      end

      if char == "("
        depth += 1
      elsif char == ")"
        break if depth.zero?

        depth -= 1
      end

      position += 1
    end

    unless position < line.length && line[position] == ")"
      rendered << line[index, marker + 2 - index]
      index = marker + 2
      next
    end

    rendered << line[index...link_start]
    rendered << line[(label_start + 1)...marker] unless image
    index = position + 1
  end

  rendered << line[index..] if index < line.length
  rendered
end

def reference_scan_line(line)
  return "" if line.match?(REFERENCE_LINK_DEFINITION_PATTERN)

  scan_line = reference_code_text(line)
    .gsub(%r{<https?://[^>\s]+>}, "")
    .gsub(%r{\bhttps?://\S+}, "")
  rendered_inline_links(scan_line)
    .gsub(/(?<!!)\[([^\]]+)\]\[[^\]]*\]/, "\\1")
    .gsub(/!\[[^\]]*\]\[[^\]]*\]/, "")
end

def record_definition(definitions, id, path, line)
  definitions[id] << Definition.new(id: id, path: relative(path), line: line)
end

def collect_definitions_and_references(files)
  # Bucket definitions by source so we can resolve canonical authorship:
  # heading / ASM bullet / ADR filename rank above table-row definitions.
  # When canonical sources exist for an ID, table-row occurrences become
  # references instead of duplicate definitions. This matches docs that
  # carry a TOC summary table + canonical detail heading + cross-doc summary
  # tables for the same ID.
  canonical_defs = Hash.new { |hash, key| hash[key] = [] }
  table_defs = Hash.new { |hash, key| hash[key] = [] }
  references = []
  adr_filename_errors = []

  files.each do |path|
    file_defined_ids = Set.new

    content_lines(path) do |line, number|
      reference_scan_line(line).scan(ID_PATTERN) do |id|
        references << Reference.new(id: id, path: relative(path), line: number)
      end

      if (match = line.match(/^\s{0,3}#+\s+`?(#{ID_PATTERN.source})`?(?::|\b)/))
        canonical_defs[match[1]] << Definition.new(id: match[1], path: relative(path), line: number)
        file_defined_ids << match[1]
      end

      # Consolidation pattern: heading like `#### Originally DEC-016: …` or
      # `## Removed Q-005: …` defines the ID for resolution lookups, even
      # though the canonical entry has been merged elsewhere. Require a
      # strict trailing colon so prose like `## Note REQ-001 is open` does
      # not get mis-classified as a definition.
      if (match = line.match(/^\s{0,3}#+\s+[A-Za-z][A-Za-z-]*\s+`?(#{ID_PATTERN.source})`?:/))
        canonical_defs[match[1]] << Definition.new(id: match[1], path: relative(path), line: number)
        file_defined_ids << match[1]
      end

      if (match = line.match(/^\s*\|\s*`?(#{ID_PATTERN.source})`?\s*\|/))
        table_defs[match[1]] << Definition.new(id: match[1], path: relative(path), line: number)
        file_defined_ids << match[1]
      end

      next unless (match = line.match(/^\s*[-*]\s+`?(ASM-\d{3,4})`?\s*:/))

      canonical_defs[match[1]] << Definition.new(id: match[1], path: relative(path), line: number)
      file_defined_ids << match[1]
    end

    rel = relative(path)
    next unless rel.start_with?("docs/adr/")
    next unless (match = File.basename(rel).match(/\A(?:ADR-)?(\d{3,4})(?:[-_.]|$)/i))

    id = "ADR-#{match[1]}"
    defined_adr_ids = file_defined_ids.select { |defined_id| defined_id.start_with?("ADR-") }
    if defined_adr_ids.empty?
      canonical_defs[id] << Definition.new(id: id, path: relative(path), line: 1)
    elsif !defined_adr_ids.include?(id)
      adr_filename_errors << "#{rel}:1 ADR filename implies #{id} but content defines #{defined_adr_ids.to_a.sort.join(', ')}"
    end
  end

  # Resolution: canonical (heading / ASM bullet / ADR filename) wins over
  # table-row. When both exist for an ID, demote table-row occurrences to
  # references so they neither dangle nor inflate duplicate counts.
  definitions = Hash.new { |hash, key| hash[key] = [] }
  all_ids = canonical_defs.keys.to_set | table_defs.keys.to_set
  all_ids.each do |id|
    if canonical_defs.key?(id) && !canonical_defs[id].empty?
      definitions[id] = canonical_defs[id]
      table_defs[id].each do |td|
        references << Reference.new(id: id, path: td.path, line: td.line)
      end
    else
      definitions[id] = table_defs[id]
    end
  end

  [definitions, references, adr_filename_errors]
end

def check_duplicate_definitions(definitions)
  definitions.each_with_object([]) do |(id, locations), errors|
    next unless locations.length > 1

    where = locations.map { |location| "#{location.path}:#{location.line}" }.join(", ")
    errors << "duplicate definition for #{id}: #{where}"
  end
end

def check_dangling_references(definitions, references)
  defined_ids = definitions.keys.to_set
  missing = references.reject { |reference| defined_ids.include?(reference.id) }

  missing.group_by(&:id).map do |id, refs|
    where = refs.first(5).map { |ref| "#{ref.path}:#{ref.line}" }.join(", ")
    suffix = refs.length > 5 ? " (+#{refs.length - 5} more)" : ""
    "dangling reference to #{id}: #{where}#{suffix}"
  end
end

def check_must_requirements(files)
  errors = []

  files.each do |path|
    content_lines(path) do |line, number|
      next unless line.match?(/^\s*\|\s*`?REQ-\d{3,4}`?\s*\|/)

      cells = line.strip.delete_prefix("|").delete_suffix("|").split("|").map(&:strip)
      id = cells.first.to_s.tr("`", "")
      priority_index = cells.index { |cell| cell.downcase.tr("`", "") == "must" }
      next unless priority_index

      related_ac_text = cells[(priority_index + 1)..]&.join(" | ").to_s
      next if reference_scan_line(related_ac_text).match?(AC_ID_PATTERN)

      errors << "#{relative(path)}:#{number} must requirement #{id} has no AC link"
    end
  end

  errors
end

def check_placeholders(files)
  errors = []

  files.each do |path|
    content_lines(path) do |line, number|
      scan_line = reference_code_text(line)

      PLACEHOLDER_PATTERNS.each do |pattern|
        next unless (match = scan_line.match(pattern))

        errors << "#{relative(path)}:#{number} placeholder/template remnant: #{match[0]}"
        break
      end
    end
  end

  errors
end

def thin_doc_edit_marker_entry_count(line, in_marker: false)
  marker_index = line.index("Thin-doc edits since:")
  if marker_index
    marker = line[(marker_index + "Thin-doc edits since:".length)..].to_s
    return marker.split(/\s*(?:→|->)\s*/).reject(&:empty?).length
  end

  return 0 unless in_marker

  _, content = blockquote_depth_and_content(line)
  stripped = content.strip
  return 0 unless stripped.start_with?("→", "->")

  stripped.sub(/\A(?:→|->)\s*/, "").empty? ? 0 : 1
end

def check_compact_first_read_docs
  errors = []

  COMPACT_FIRST_READ_DOCS.each do |rel|
    path = ROOT.join(rel)
    next unless path.file?

    paragraph_start = nil
    paragraph_bytes = 0
    marker_start = nil
    marker_entries = 0

    content_lines(path) do |line, number|
      if line.length > MAX_COMPACT_LINE_CHARS
        errors << "#{rel}:#{number} line exceeds #{MAX_COMPACT_LINE_CHARS} chars (#{line.length}); split wide rows or prose"
      end

      current_marker_entries = thin_doc_edit_marker_entry_count(line, in_marker: !marker_start.nil?)
      if line.include?("Thin-doc edits since:")
        marker_start = number
        marker_entries = current_marker_entries
      elsif marker_start && current_marker_entries.positive?
        marker_entries += current_marker_entries
      elsif marker_start
        marker_start = nil
        marker_entries = 0
      end

      if marker_start && marker_entries > MAX_THIN_DOC_EDIT_MARKER_ENTRIES
        errors << "#{rel}:#{marker_start} Thin-doc edits since marker has #{marker_entries} entries; compact to <= #{MAX_THIN_DOC_EDIT_MARKER_ENTRIES}"
        marker_start = nil
        marker_entries = 0
      end

      if line.strip.empty?
        if paragraph_bytes > MAX_COMPACT_PARAGRAPH_BYTES
          errors << "#{rel}:#{paragraph_start} paragraph exceeds #{MAX_COMPACT_PARAGRAPH_BYTES} bytes (#{paragraph_bytes}); move cycle history out of active docs"
        end
        paragraph_start = nil
        paragraph_bytes = 0
        next
      end

      paragraph_start ||= number
      paragraph_bytes += line.bytesize + 1
    end

    next unless paragraph_bytes > MAX_COMPACT_PARAGRAPH_BYTES

    errors << "#{rel}:#{paragraph_start} paragraph exceeds #{MAX_COMPACT_PARAGRAPH_BYTES} bytes (#{paragraph_bytes}); move cycle history out of active docs"
  end

  errors
end

def merge_time_check_path?(path)
  rel = relative(path)
  MERGE_TIME_CHECK_PREFIXES.any? do |prefix|
    prefix.end_with?("/") ? rel.start_with?(prefix) : rel == prefix
  end
end

def check_merge_time_drift(files)
  errors = []

  files.each do |path|
    next unless merge_time_check_path?(path)

    content_lines(path) do |line, number|
      scan_line = reference_code_text(line)

      MERGE_TIME_DRIFT_PATTERNS.each do |pattern|
        next unless (match = scan_line.match(pattern))

        errors << "#{relative(path)}:#{number} merge-time placeholder: #{match[0].strip}"
        break
      end
    end
  end

  errors
end

def sha_token_exists?(token)
  system("git", "-C", ROOT.to_s, "rev-parse", "--verify", "--quiet",
         "#{token}^{commit}", out: File::NULL, err: File::NULL)
end

def sha_reachable_from_head?(token)
  system("git", "-C", ROOT.to_s, "merge-base", "--is-ancestor",
         token, "HEAD", out: File::NULL, err: File::NULL)
end

def split_gfm_table_row(line)
  # GitHub-Flavored Markdown table cells are pipe-delimited but `\|`
  # escapes a literal pipe inside a cell. A naive `split("|")` would
  # shift cell indices whenever a row uses an escaped pipe in Goal /
  # Evidence prose, causing `cells[8]` to land on the wrong column.
  inner = line.strip.delete_prefix("|").delete_suffix("|")
  cells = []
  current = String.new
  escape = false
  inner.each_char do |char|
    if escape
      current << char
      escape = false
    elsif char == "\\"
      current << char
      escape = true
    elsif char == "|"
      cells << current
      current = String.new
    else
      current << char
    end
  end
  cells << current
  cells
end

def parse_impl_plan_slice_table
  empty_result = [{}, []]
  return empty_result if IMPL_PLAN_PATH.empty?

  path = ROOT.join(IMPL_PLAN_PATH)
  return empty_result unless path.file?

  status_map = {}
  slice_lines = Hash.new { |hash, key| hash[key] = [] }
  in_slice_table = false
  slice_column = nil
  status_column = nil
  # PR-E: track whether we've seen the separator row that closes the
  # GFM table header. Before the separator, every `| ... |` line is a
  # header row (`| Slice | Milestone | ... |`) and must not be parsed
  # as data — otherwise a plan with two `Phases / Slices` tables
  # would falsely register a duplicate `Slice` row (codex P2 on PR-E).
  past_separator = false

  content_lines(path) do |line, number|
    if line.match?(/\A\s{0,3}[#]{1,6}\s+(Phases|Slices)/i)
      in_slice_table = true
      past_separator = false
      slice_column = nil
      status_column = nil
      next
    elsif line.match?(ANY_HEADING_PATTERN)
      in_slice_table = false
      past_separator = false
      slice_column = nil
      status_column = nil
      next
    end

    next unless in_slice_table
    next unless line.match?(/\A\s*\|/)

    cells = split_gfm_table_row(line).map do |cell|
      cell.strip.gsub(/\A`|`\z/, "").strip.gsub(/\\\|/, "|")
    end
    next if cells.empty?

    unless past_separator
      normalized_cells = cells.map { |cell| cell.downcase }
      slice_column = normalized_cells.index("slice")
      status_column = normalized_cells.index("status")
    end

    # Detect the table separator row (all cells are :?-+:?). The next
    # data row (and onwards) is treated as real slice data.
    if cells.all? { |cell| cell.match?(/\A:?-+:?\z/) }
      past_separator = true
      next
    end

    # Before the separator: header row(s) — skip without registering
    # any slice. After the separator: real data rows.
    next unless past_separator
    next if slice_column.nil? || status_column.nil?
    next if cells.length <= [slice_column, status_column].max

    slice = cells[slice_column]
    status = cells[status_column]
    next if slice.empty? || status.empty?
    next if slice.start_with?("<", "-") # skip template placeholder rows

    slice_lines[slice] << number
    status_map[slice] = status
  end

  duplicates = slice_lines.select { |_slice, lines| lines.size > 1 }
                          .map { |slice, lines| { slice: slice, lines: lines } }

  [status_map, duplicates]
end

def parse_impl_plan_slice_status
  parse_impl_plan_slice_table[0]
end

def impl_plan_ledger_available?
  return false if IMPL_PLAN_PATH.empty?

  ROOT.join(IMPL_PLAN_PATH).file?
end

def check_impl_plan_duplicate_slices(_files)
  errors = []
  return errors unless impl_plan_ledger_available?

  _status_map, duplicates = parse_impl_plan_slice_table
  duplicates.each do |entry|
    errors << "#{IMPL_PLAN_PATH}: duplicate slice row `#{entry[:slice]}` at lines #{entry[:lines].join(', ')} — last-write-wins on the status table silently picks one row and breaks ledger integrity"
  end

  errors
end

def check_pending_anchors(files)
  warnings = []
  ledger_available = impl_plan_ledger_available?
  # If the ledger is unavailable (path empty or file missing), the
  # entire reaping check is disabled per the PR-3 contract. Returning
  # an empty status_map here would still let the new unknown-anchor
  # branch fire on every slice-looking anchor — PR-B P1 codex
  # finding. Gate both branches on `ledger_available`.
  status_map = ledger_available ? parse_impl_plan_slice_status : {}

  files.each do |path|
    next unless merge_time_check_path?(path)

    pending_depth = nil
    closed_subsection_depth = nil

    content_lines(path) do |line, number|
      # Track heading depth so nested subsections under `## Pending`
      # stay inside scope, AND track whether we're inside a closed
      # subsection (### Closed / Done / Resolved / Reaped / Completed)
      # to suppress reaping warnings for items the author has already
      # marked closed.
      if (depth_match = line.match(/\A\s{0,3}([#]{1,6})\s/))
        current_depth = depth_match[1].length

        # Exit the closed subsection when a heading at the same or
        # shallower depth lands; depth comparison runs before any new
        # heading is recorded.
        if closed_subsection_depth && current_depth <= closed_subsection_depth
          closed_subsection_depth = nil
        end

        # Exit the Pending section when a heading at the same or
        # shallower depth lands. A reset of Pending also resets any
        # active closed subsection.
        if pending_depth && current_depth <= pending_depth
          pending_depth = nil
          closed_subsection_depth = nil
        end

        if line.match?(PENDING_HEADING_PATTERN)
          pending_depth = current_depth
          closed_subsection_depth = nil
        elsif pending_depth && line.match?(CLOSED_SUBSECTION_HEADING_PATTERN) && current_depth > pending_depth
          # Only mark as closed subsection if it is strictly deeper
          # than `## Pending`; a `## Closed` sibling-level heading is
          # an exit, not a nested subsection (handled by the exit
          # branch above).
          closed_subsection_depth = current_depth
        end

        next
      end

      next if pending_depth.nil?
      next if closed_subsection_depth # inside ### Closed → suppress

      # Collect `closed by <anchor>` annotations on this line. A
      # Pending anchor whose target appears in this list is suppressed
      # — the author has explicitly recorded the closure. Mismatched
      # closed-by targets (e.g. `closed by EX-1A.99` when the anchor
      # is `EX-1A.5`) do NOT suppress, because the closure is
      # incomplete.
      closed_by_targets = line.scan(CLOSED_BY_PATTERN).map do |captures|
        captures[0].to_s.gsub(/\A`|`\z/, "").strip.chomp(".").chomp(",").chomp(")")
      end

      line.scan(PENDING_ANCHOR_PATTERN) do |captures|
        anchor = captures[0].to_s.gsub(/`/, "").strip
        next if anchor.empty?
        next if closed_by_targets.include?(anchor)

        status = status_map[anchor]
        if status && REAPED_STATUSES.include?(status.downcase)
          warnings << "#{relative(path)}:#{number} Pending item references slice `#{anchor}` already #{status.downcase} in #{IMPL_PLAN_PATH}"
        elsif ledger_available && !status && anchor.match?(SLICE_LIKE_ANCHOR_PATTERN)
          warnings << "#{relative(path)}:#{number} Pending item references unknown slice-looking anchor `#{anchor}` (not found in #{IMPL_PLAN_PATH}; possible typo)"
        end
      end
    end
  end

  warnings
end

def load_counted_state_config
  return nil if COUNTED_STATE_PATH.empty?

  path = ROOT.join(COUNTED_STATE_PATH)
  return nil unless path.file?

  require "yaml"

  begin
    YAML.safe_load(path.read, permitted_classes: [Symbol], aliases: false)
  rescue Psych::Exception => e
    # PR-E hardening: previously rescued only `Psych::SyntaxError`
    # and `Psych::DisallowedClass`. A YAML using alias references
    # (`*name`) raises `Psych::BadAlias` / `Psych::AliasesNotEnabled`
    # depending on Ruby/Psych version, neither of which inherits from
    # the previous list — a single alias-using config would crash
    # the whole governance check. `Psych::Exception` is the base
    # class for all Psych errors and future-proofs against new
    # subclasses.
    { "__parse_error" => "#{COUNTED_STATE_PATH}: #{e.message}" }
  end
end

def check_counted_state(files)
  warnings = []
  config = load_counted_state_config
  return warnings if config.nil?

  # The config can be anything YAML parses to (Array, scalar, etc.).
  # Indexing into a non-Hash raises TypeError, so gate every key access
  # behind an explicit is_a? check before reading parse-error metadata
  # or `counts`.
  if config.is_a?(Hash) && (err = config["__parse_error"])
    warnings << "counted-state config: failed to parse #{err}"
    return warnings
  end

  counts = config.is_a?(Hash) ? config["counts"] : nil
  return warnings unless counts.is_a?(Hash) && !counts.empty?

  files_by_path = files.each_with_object({}) { |path, hash| hash[relative(path)] = path }

  counts.each do |key, decl|
    next unless decl.is_a?(Hash)

    value = decl["value"]
    raw_terms = decl["terms"]
    next unless value.is_a?(Integer) && raw_terms.is_a?(Array)

    # Filter out null / non-string / empty-string term entries before
    # building the alternation regex. Without this, `terms: [null]`
    # would coerce to `""` and the resulting regex `(?:)` matches
    # every numeric token in scope.
    terms = raw_terms.select { |term| term.is_a?(String) && !term.empty? }
    next if terms.empty?

    raw_scan_paths = decl["scan_paths"]
    scan_paths = if raw_scan_paths.is_a?(Array)
                   # Same defensive filter for scan_paths — a single
                   # null or numeric YAML entry would crash the script
                   # on `String#end_with?`.
                   raw_scan_paths.select { |entry| entry.is_a?(String) && !entry.empty? }
                 else
                   []
                 end
    scan_paths = MERGE_TIME_CHECK_PREFIXES if scan_paths.empty?

    term_alternation = terms.map { |term| Regexp.escape(term) }.join("|")
    count_pattern = /(?<![\w.-])(\d+)\s*[-]?\s*(?:#{term_alternation})\b/i

    scan_paths.each do |scan_path|
      matching_files = files_by_path.select do |rel, _|
        if scan_path.end_with?("/")
          rel.start_with?(scan_path)
        else
          rel == scan_path
        end
      end.values

      matching_files.each do |file_path|
        content_lines(file_path) do |line, number|
          # Match-local qualifier scan (PR-C). Previously a single
          # qualifier anywhere on the line silenced every drift count
          # on it, so `Current runtime has 6 axes; previous baseline
          # was 5 axes` would suppress the `6` drift along with the
          # historical `5`. Now each match is gated on its own
          # clause-scoped prefix.
          line.to_enum(:scan, count_pattern).each do
            match_data = Regexp.last_match
            next if match_data.nil?

            actual = match_data[1].to_i
            next if actual == value

            start_pos = match_data.begin(0)
            window_start = [start_pos - COUNTED_STATE_QUALIFIER_WINDOW, 0].max
            prefix_window = line[window_start...start_pos]
            boundary_index = prefix_window.rindex(COUNTED_STATE_CLAUSE_BOUNDARY)
            clause_prefix = boundary_index ? prefix_window[(boundary_index + 1)..] : prefix_window

            next if HISTORICAL_QUALIFIERS.any? { |qualifier| clause_prefix.match?(qualifier) }

            # Report the literal regex match without whitespace
            # normalization. PR-C codex review: collapsing `6     axes`
            # to `6 axes` hides exactly the kind of boundary/width
            # regression the matched-phrase reporting exists to catch.
            matched_phrase = match_data[0]
            warnings << "#{relative(file_path)}:#{number} counted_state `#{key}` mismatch: matched `#{matched_phrase}` says `#{actual}` but config declares `#{value}` (terms: #{terms.join(', ')})"
          end
        end
      end
    end
  end

  warnings
end

def check_sha_freshness_headers(files)
  errors = []
  header_seen_at = nil

  files.each do |path|
    next unless merge_time_check_path?(path)

    content_lines(path) do |line, number|
      next unless (match = line.match(SHA_HEADER_LINE_PATTERN))

      token = match[1].chomp(",").chomp(")")
      # Skip tokens already flagged by merge-time-drift (e.g. `pending`,
      # `on branch ...`, branch-shaped paths). Reporting them here adds
      # noise without new information.
      next if token =~ /\Apending\z/i

      unless token.match?(SHA_TOKEN_FORMAT)
        errors << "#{relative(path)}:#{number} SHA header token is not a 7-40 hex commit SHA: #{token.inspect}"
        next
      end

      # PR-E: the documented header shape carries `(YYYY-MM-DD)`.
      # Missing or malformed date is part of the contract surface.
      unless line.match?(SHA_HEADER_DATE_PATTERN)
        errors << "#{relative(path)}:#{number} SHA header missing or malformed `(YYYY-MM-DD)` date suffix"
        next
      end

      header_seen_at ||= "#{relative(path)}:#{number}"

      # PR-A hardening: shallow clones can no longer skip silently. If
      # the operator has not explicitly waived the check, surface the
      # gap as an error and refuse to false-pass.
      if SHALLOW_CLONE && !EXPLICIT_SKIP_SHA_VERIFY
        errors << "#{relative(path)}:#{number} SHA header existence/ancestry skipped: repository is shallow. Use `fetch-depth: 0` in CI checkout or set `DOC_GOVERNANCE_SKIP_SHA_VERIFY=1` as an explicit waiver."
        next
      end

      next if SKIP_SHA_VERIFY

      unless sha_token_exists?(token)
        errors << "#{relative(path)}:#{number} SHA header token not found in local git history: #{token}"
        next
      end

      # PR-mode contract: the header must reference a commit reachable
      # from the PR branch's HEAD, not just any commit object present in
      # `.git/objects` (which would let dangling commits or commits on
      # unrelated branches false-pass).
      unless sha_reachable_from_head?(token)
        errors << "#{relative(path)}:#{number} SHA header token not reachable from HEAD: #{token}"
      end
    end
  end

  if SKIP_SHA_VERIFY && header_seen_at
    # Explicit waiver still emits a stderr notice so CI logs record that
    # the check was disabled by operator intent rather than silently.
    warn "Doc governance notice: DOC_GOVERNANCE_SKIP_SHA_VERIFY=1 in effect; existence + ancestry checks were skipped for SHA headers (first header at #{header_seen_at})."
  end

  errors
end

all_markdown_files = markdown_files
active_files = all_markdown_files.select { |path| active_doc?(path) }
symlink_errors = reject_symlinked_markdown(active_files)
active_files = active_files.reject(&:symlink?)
definitions, references, adr_filename_errors = collect_definitions_and_references(active_files)

errors = []
errors.concat(symlink_errors)
errors.concat(adr_filename_errors)
errors.concat(check_duplicate_definitions(definitions))
errors.concat(check_dangling_references(definitions, references))
errors.concat(check_must_requirements(active_files))
errors.concat(check_merge_time_drift(active_files))
errors.concat(check_sha_freshness_headers(active_files))
errors.concat(check_impl_plan_duplicate_slices(active_files))
errors.concat(check_placeholders(active_files)) if STRICT
errors.concat(check_compact_first_read_docs)

# Advisory warnings — exit 0 unless STRICT promotes them to errors. The
# Pending reaping check is opt-in convention, so flagging stale anchors
# is informative for opted-in repos but should not break builds for
# everyone else who does not yet use `[pending-anchor: …]` metadata.
warnings = []
warnings.concat(check_pending_anchors(active_files))
warnings.concat(check_counted_state(active_files))

if STRICT
  errors.concat(warnings)
  warnings = []
end

mode = STRICT ? "strict" : "default"

unless warnings.empty?
  warn "Doc governance warnings (#{mode} mode, advisory, exit 0):"
  warnings.each { |warning| warn "- #{warning}" }
end

if errors.empty?
  suffix = warnings.empty? ? "" : " with #{warnings.length} advisory warning#{warnings.length == 1 ? "" : "s"}"
  puts "Doc governance check passed#{suffix} (#{mode} mode, #{active_files.length} active Markdown files, #{definitions.length} IDs)."
  exit 0
end

warn "Doc governance check failed:"
errors.each { |error| warn "- #{error}" }
exit 1
