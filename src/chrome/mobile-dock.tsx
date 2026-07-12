import { useMemo, useState } from "react";
import { Search, X } from "lucide-react";
import { NAV_ITEMS, applyNavCustomization, type NavItem } from "@/chrome/nav-items";
import { ParentalPinModal } from "@/components/parental-pin-modal";
import { useT } from "@/lib/i18n";
import { useParental } from "@/lib/parental";
import { useActiveKid } from "@/lib/profiles";
import { useSearch } from "@/lib/search-context";
import { useSettings } from "@/lib/settings";
import { useView, type View } from "@/lib/view";

/** Tab ids pinned to the bottom bar; everything else lives in the More sheet. */
const DOCK_IDS = ["home", "discover", "library"] as const;

export function MobileDock() {
  const { view, setView, chromeHidden, topKind } = useView();
  const { locked, unlock, hiddenTabs } = useParental();
  const { settings } = useSettings();
  const { setOpen: setSearchOpen } = useSearch();
  const kid = useActiveKid();
  const t = useT();
  const [moreOpen, setMoreOpen] = useState(false);
  const [pendingPinView, setPendingPinView] = useState<View | null>(null);

  const visible = useMemo(() => {
    const items = applyNavCustomization(NAV_ITEMS, settings.navCustomization);
    return items.filter((item) => {
      if (kid) return item.view === "kids";
      if (item.view === "kids") return false;
      if (item.view === "vod" && !settings.showPlaylistsTab) return false;
      if (item.hideKey && settings.hideContent[item.hideKey]) return false;
      if (locked && item.parentalKey && hiddenTabs[item.parentalKey]) return false;
      return true;
    });
  }, [settings.navCustomization, settings.showPlaylistsTab, settings.hideContent, kid, locked, hiddenTabs]);

  const dockItems = visible.filter((item) => (DOCK_IDS as readonly string[]).includes(item.id));
  const moreItems = visible.filter((item) => !(DOCK_IDS as readonly string[]).includes(item.id));

  const navigate = (item: NavItem) => {
    setMoreOpen(false);
    setSearchOpen(false);
    if (item.pinGated && locked) {
      setPendingPinView(item.view);
      return;
    }
    setView(item.view);
  };

  if (chromeHidden) return null;

  const tabCls = (active: boolean) =>
    `flex min-w-0 flex-1 flex-col items-center justify-center gap-1 py-1.5 transition-colors ${
      active ? "text-ink" : "text-ink-subtle active:text-ink-muted"
    }`;

  const moreActive = moreItems.some((item) => view === item.view && topKind !== "home");

  return (
    <>
      <nav
        data-harbor-mobile-dock
        className="fixed inset-x-0 bottom-0 z-[70] border-t border-edge-soft bg-canvas"
        style={{ paddingBottom: "var(--safe-bottom)" }}
      >
        <div className="flex h-16 items-stretch px-1">
          {dockItems.map((item) => (
            <button
              key={item.id}
              type="button"
              data-harbor-nav={item.id}
              onClick={() => navigate(item)}
              className={tabCls(view === item.view)}
            >
              <span className="[&_svg]:h-6 [&_svg]:w-6">{item.render(view === item.view)}</span>
              <span className="max-w-full truncate text-[10.5px] font-medium leading-none">
                {t(item.label)}
              </span>
            </button>
          ))}
          <button
            type="button"
            onClick={() => {
              setMoreOpen(false);
              setSearchOpen(true);
            }}
            className={tabCls(false)}
          >
            <Search size={23} strokeWidth={2} />
            <span className="text-[10.5px] font-medium leading-none">{t("nav.search")}</span>
          </button>
          {moreItems.length > 0 && (
            <button type="button" onClick={() => setMoreOpen((v) => !v)} className={tabCls(moreOpen || moreActive)}>
              <span className="flex h-6 items-center">
                <span className="flex gap-[3px]">
                  <span className="h-[5px] w-[5px] rounded-full bg-current" />
                  <span className="h-[5px] w-[5px] rounded-full bg-current" />
                  <span className="h-[5px] w-[5px] rounded-full bg-current" />
                </span>
              </span>
              <span className="text-[10.5px] font-medium leading-none">{t("nav.more")}</span>
            </button>
          )}
        </div>
      </nav>

      {moreOpen && (
        <div className="fixed inset-0 z-[69]" onClick={() => setMoreOpen(false)}>
          <div className="harbor-backdrop-in absolute inset-0 bg-canvas/60 backdrop-blur-[2px]" />
          <div
            className="harbor-sheet-in absolute inset-x-0 rounded-t-3xl border-t border-edge-soft bg-surface shadow-2xl"
            style={{ bottom: "calc(var(--safe-bottom) + 4rem)" }}
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between px-5 pt-4">
              <span className="text-[13px] font-semibold uppercase tracking-widest text-ink-subtle">
                {t("nav.more")}
              </span>
              <button
                type="button"
                onClick={() => setMoreOpen(false)}
                className="flex h-9 w-9 items-center justify-center rounded-full bg-elevated/70 text-ink-muted"
              >
                <X size={17} />
              </button>
            </div>
            <div className="grid max-h-[55vh] grid-cols-4 gap-1 overflow-y-auto p-4">
              {moreItems.map((item) => (
                <button
                  key={item.id}
                  type="button"
                  data-harbor-nav={item.id}
                  onClick={() => navigate(item)}
                  className={`flex flex-col items-center gap-2 rounded-2xl px-1 py-3.5 transition-colors ${
                    view === item.view ? "bg-raised text-ink" : "text-ink-muted active:bg-elevated/70"
                  }`}
                >
                  <span className="[&_svg]:h-6 [&_svg]:w-6">{item.render(view === item.view)}</span>
                  <span className="max-w-full truncate text-[11px] font-medium leading-none">
                    {t(item.label)}
                  </span>
                </button>
              ))}
            </div>
          </div>
        </div>
      )}

      {pendingPinView && (
        <ParentalPinModal
          mode={{
            kind: "unlock",
            onUnlock: () => {
              const v = pendingPinView;
              setPendingPinView(null);
              if (v) setView(v);
            },
            onCancel: () => setPendingPinView(null),
          }}
          verify={unlock}
        />
      )}
    </>
  );
}
