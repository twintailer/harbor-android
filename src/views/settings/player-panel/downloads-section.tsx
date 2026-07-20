import { documentDir, downloadDir } from "@tauri-apps/api/path";
import { open } from "@tauri-apps/plugin-dialog";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { FolderOpen, RotateCcw } from "lucide-react";
import { useEffect, useState } from "react";
import { useSettings } from "@/lib/settings";
import { isMobileTauri } from "@/lib/platform";
import { ToggleRow } from "@/views/settings/shared";

export function DownloadsSection() {
  const { settings, update } = useSettings();
  const [systemDefault, setSystemDefault] = useState<string>("");
  const mobile = isMobileTauri();

  useEffect(() => {
    let cancelled = false;
    // iOS: writable + Files-visible location is Documents (see downloads-store).
    (mobile ? documentDir() : downloadDir())
      .then((d) => {
        if (!cancelled) setSystemDefault(d);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [mobile]);

  const current = settings.downloadDir || systemDefault;
  const isCustom = !!settings.downloadDir;

  const pickFolder = async () => {
    try {
      const picked = await open({
        directory: true,
        defaultPath: current || undefined,
      });
      if (typeof picked === "string") {
        update({ downloadDir: picked });
      }
    } catch {
      return;
    }
  };

  const resetToDefault = () => {
    update({ downloadDir: "" });
  };

  const revealCurrent = async () => {
    if (!current) return;
    try {
      await revealItemInDir(current);
    } catch {
      return;
    }
  };

  return (
    <div className="flex flex-col gap-3">
      <ToggleRow
        label="Create folders for movies and shows"
        note="Organize downloads into folders by movie or series name"
        value={settings.downloadCreateFolders}
        onChange={(v) => update({ downloadCreateFolders: v })}
      />
      <div className="flex items-center justify-between gap-3 rounded-xl border border-edge-soft bg-canvas/40 px-4 py-3">
        <div className="flex min-w-0 flex-col gap-0.5">
          <span className="text-[11.5px] font-semibold uppercase tracking-[0.16em] text-ink-subtle">
            {isCustom ? "Custom location" : "System default"}
          </span>
          <span className="truncate font-mono text-[13px] text-ink" title={current}>
            {current || "Detecting..."}
          </span>
        </div>
        {!mobile && current && (
          <button
            type="button"
            onClick={revealCurrent}
            className="flex h-9 shrink-0 items-center gap-1.5 rounded-lg border border-edge-soft px-3 text-[12.5px] font-medium text-ink-muted transition-colors hover:border-edge hover:text-ink"
          >
            <FolderOpen size={13} strokeWidth={2.2} />
            Open
          </button>
        )}
      </div>
      {/* iOS: no folder picker and the sandbox only allows Documents. */}
      {!mobile && (
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={pickFolder}
            className="flex h-10 items-center gap-2 rounded-lg bg-ink px-4 text-[13px] font-semibold text-canvas transition-transform hover:scale-[1.02] active:scale-[0.97]"
          >
            Choose folder
          </button>
          {isCustom && (
            <button
              type="button"
              onClick={resetToDefault}
              className="flex h-10 items-center gap-1.5 rounded-lg border border-edge-soft px-3 text-[12.5px] font-medium text-ink-muted transition-colors hover:border-edge hover:text-ink"
            >
              <RotateCcw size={13} strokeWidth={2.2} />
              Reset to default
            </button>
          )}
        </div>
      )}
    </div>
  );
}
