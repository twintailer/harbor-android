import { PickCard } from "@/components/pick-card";
import { Row } from "@/components/row";
import { useT } from "@/lib/i18n";
import { useAnilistTop, useAnilistTrending } from "@/lib/use-anilist-top";

export function AnilistTrendingRow() {
  const t = useT();
  const metas = useAnilistTrending();
  if (metas.length === 0) return null;
  return (
    <div data-scroll-anchor="row:anilist-trending">
      <Row title={t("Trending on AniList")} scrollKey="anime:anilist-trending">
        {metas.map((m, i) => (
          <PickCard key={`${m.id}-${i}`} meta={m} />
        ))}
      </Row>
    </div>
  );
}

export function AnilistTopRow() {
  const t = useT();
  const metas = useAnilistTop();
  if (metas.length === 0) return null;
  return (
    <div data-scroll-anchor="row:anilist-top">
      <Row title={t("Top 100 on AniList")} scrollKey="anime:anilist-top">
        {metas.map((m, i) => (
          <PickCard key={`${m.id}-${i}`} meta={m} />
        ))}
      </Row>
    </div>
  );
}
