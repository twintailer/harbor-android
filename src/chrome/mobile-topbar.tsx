import { ArrowLeft } from "lucide-react";
import { HarborMark } from "@/components/icons/harbor-mark";
import { ProfileChip } from "@/chrome/sidebar/profile-chip";
import { useT } from "@/lib/i18n";
import { useView } from "@/lib/view";

/**
 * Slim top chrome for the phone shell: back affordance on stacked views,
 * wordmark on root views, profile chip on the trailing edge. Sits below the
 * status bar via the shared [data-harbor-topbar] safe-area rule.
 */
export function MobileTopbar() {
  const { canGoBack, goBack, chromeHidden } = useView();
  const t = useT();
  if (chromeHidden) return null;
  return (
    <header
      className="fixed inset-x-0 top-0 z-[55] flex items-center gap-2 bg-gradient-to-b from-canvas via-canvas/80 to-transparent px-3 pb-3"
      style={{ paddingTop: "calc(var(--safe-top) + 0.375rem)" }}
    >
      {canGoBack ? (
        <button
          type="button"
          onClick={() => goBack()}
          className="flex h-10 items-center gap-1.5 rounded-full border border-edge-soft bg-canvas/80 px-3.5 text-[14px] font-medium text-ink backdrop-blur-xl active:bg-elevated"
        >
          <ArrowLeft size={17} />
          {t("common.back")}
        </button>
      ) : (
        <div className="flex items-center gap-1.5 ps-1">
          <HarborMark className="h-8 w-8" />
          <span
            className="text-[26px] font-medium leading-none tracking-tight text-ink"
            style={{ fontFamily: '"Fraunces", "Iowan Old Style", "Georgia", serif' }}
          >
            Harb
            <span className="inline-block" style={{ transform: "rotate(7deg)", transformOrigin: "50% 65%" }}>
              o
            </span>
            r
          </span>
        </div>
      )}
      <div className="ms-auto flex items-center">
        <ProfileChip collapsed />
      </div>
    </header>
  );
}
