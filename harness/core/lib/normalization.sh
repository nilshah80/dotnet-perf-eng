#!/usr/bin/env bash
# Package-level normalization record helpers. Sourced by normalize-runtime.sh;
# expects jqd from common.sh (or a test's own definition).

# normalization_merge_limitations <normalization.json> <limitations.json>
#
# A normalizer can succeed with a recorded limitation: an extended SOS command
# failed while the thread and heap listing was kept, and a single-kind capture
# has no per-stage record to carry that. The adapter writes the limitations as
# a JSON array of strings; this merges them into the package's normalization
# record. No limitations file, or an empty one, leaves the record untouched. A
# malformed file is refused rather than silently dropped: the record must not
# read as clean when the adapter said it was not.
normalization_merge_limitations() {
  local record="$1" limitations="$2"
  [[ -s "${limitations}" ]] || return 0
  if ! jqd -e 'type == "array" and all(type == "string")' < "${limitations}" >/dev/null 2>&1; then
    # The adapter said the normalization had limitations and then wrote them
    # unreadably. The record must not read as clean: note that, best-effort,
    # and still report the refusal.
    if jqd -c '. + {limitations: ((.limitations // []) + ["normalization limitations file was malformed and could not be merged; see the retained runtime reports"])}' \
        < "${record}" > "${record}.tmp" 2>/dev/null; then
      mv "${record}.tmp" "${record}"
    else
      rm -f "${record}.tmp"
    fi
    echo "normalization limitations at ${limitations} are not a JSON array of strings." >&2
    return 1
  fi
  if jqd -c --argjson limitations "$(cat "${limitations}")" '. + {limitations: $limitations}' \
      < "${record}" > "${record}.tmp" 2>/dev/null; then
    mv "${record}.tmp" "${record}"
  else
    rm -f "${record}.tmp"
    echo "could not merge ${limitations} into ${record}." >&2
    return 1
  fi
}
