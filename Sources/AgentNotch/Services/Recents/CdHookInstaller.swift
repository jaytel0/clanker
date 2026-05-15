import Foundation

/// Installs / removes a zsh `chpwd` hook that appends `cd` events to a log
/// file Agent Notch reads to score project recency.
///
/// The hook lives between marker lines inside `~/.zshrc` so we can install,
/// re-install (idempotent — replaces any prior block), and uninstall cleanly
/// without disturbing the user's other config.
///
/// Design notes:
/// * No filtering happens shell-side. The hook always appends `<unix_ts>\t<PWD>`
///   and `CdLog` filters by configured roots at read time. Keeps the hook
///   trivially short and lets settings changes take effect without rewriting
///   `.zshrc`.
/// * The block also seeds `chpwd_functions` and runs the logger once at load
///   so brand-new shells immediately produce a signal for the cwd they were
///   spawned in.
enum CdHookInstaller {
    /// Path to `~/.zshrc`. We do not touch `.zprofile` / `.zshenv` — `chpwd`
    /// hooks belong in interactive-shell config.
    static let zshrcPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".zshrc")

    static let beginMarker = "# >>> agent-notch chpwd hook >>>"
    static let endMarker = "# <<< agent-notch chpwd hook <<<"

    static var hookBlock: String {
        """
        \(beginMarker)
        # Managed by Agent Notch. Do not edit between markers — reinstall from Settings.
        __agent_notch_log_cd() {
          local log_dir="${HOME}/Library/Application Support/AgentNotch"
          local log_file="${log_dir}/cd-log.tsv"
          [[ -d "$log_dir" ]] || mkdir -p "$log_dir"
          printf '%s\\t%s\\n' "$(date +%s)" "$PWD" >> "$log_file"
        }
        typeset -ga chpwd_functions
        chpwd_functions+=(__agent_notch_log_cd)
        __agent_notch_log_cd
        \(endMarker)
        """
    }

    static func isInstalled() -> Bool {
        guard let contents = try? String(contentsOfFile: zshrcPath, encoding: .utf8) else {
            return false
        }
        return contents.contains(beginMarker) && contents.contains(endMarker)
    }

    /// Insert (or refresh) the hook block. Returns `true` on success.
    @discardableResult
    static func install() -> Bool {
        let existing = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        let stripped = removingHookBlock(from: existing)
        let separator = stripped.isEmpty || stripped.hasSuffix("\n") ? "" : "\n"
        let updated = stripped + separator + "\n" + hookBlock + "\n"
        do {
            try updated.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Remove the marker-delimited block. No-op if absent.
    @discardableResult
    static func uninstall() -> Bool {
        guard let existing = try? String(contentsOfFile: zshrcPath, encoding: .utf8) else {
            return true
        }
        let stripped = removingHookBlock(from: existing)
        guard stripped != existing else { return true }
        do {
            try stripped.write(toFile: zshrcPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Strip the hook block (and any trailing blank line that belongs to it)
    /// while leaving the rest of `.zshrc` untouched.
    private static func removingHookBlock(from contents: String) -> String {
        guard let beginRange = contents.range(of: beginMarker),
              let endRange = contents.range(of: endMarker, range: beginRange.upperBound..<contents.endIndex) else {
            return contents
        }

        // Extend the cut backward through the leading newline (so we don't
        // leave an orphan blank line) and forward through the trailing
        // newline that follows the end marker.
        var lower = beginRange.lowerBound
        while lower > contents.startIndex {
            let prev = contents.index(before: lower)
            if contents[prev] == "\n" {
                lower = prev
            } else {
                break
            }
        }

        var upper = endRange.upperBound
        if upper < contents.endIndex, contents[upper] == "\n" {
            upper = contents.index(after: upper)
        }

        var result = contents
        result.removeSubrange(lower..<upper)
        return result
    }
}
