// Homepage motion: the hero settles in on load; as you scroll, its app icon shrinks and docks
// into the VibeFlow icon in the site's menu bar while the words drift back. The sections after
// it rise in once as they reach the screen. Reduced motion gets none of it; the CSS only hides
// the hero while this is known to run (.js and no-preference).
import { gsap, ScrollTrigger, EASE, MOTION } from './motion';

// The page ground takes on each section's colour as it reaches the middle of the screen: white for
// the hero, a soft tint of the feature colour after it (the Shortcuts tour and the two dark bands
// paint their own). Voice shifts it per beat itself. Reduced motion switches without the fade.
const GROUNDS: [string, string][] = [
  ['.hero', '#FFFFFF'], ['#voice', '#F1F6FE'], ['#ask', '#F4F2FE'], ['#show', '#F5F4FC'],
  ['#tools', '#EFF7F3'], ['.extras', '#EFF7F3'], ['#pricing', '#FFFFFF'], ['#faq', '#FFFFFF'],
];
const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
const paintGround = (color: string) => {
  document.documentElement.dataset.ground = color; // shared with Voice, which paints its beats
  gsap.to(document.documentElement, { '--page': color, duration: still ? 0 : 0.8, ease: 'power2.out', overwrite: 'auto' });
};
// One tracker for the whole page, so a jump (End key, a menu link) still lands on the right colour:
// whichever listed section sits at 55% of the screen paints the ground; in between (the tour, the
// dark bands) the last colour stays.
const grounds = GROUNDS.map(([sel, color]) => [document.querySelector(sel), color] as const).filter(([el]) => el);
const pick = () => {
  const line = innerHeight * 0.55;
  for (const [el, color] of grounds) {
    const r = el!.getBoundingClientRect();
    if (r.top <= line && r.bottom > line) {
      const want = (el as HTMLElement).dataset.ground || color; // Voice sets its beat's colour here
      if (document.documentElement.dataset.ground !== want) paintGround(want);
      return;
    }
  }
};
ScrollTrigger.create({ start: 0, end: 'max', onUpdate: pick, onRefresh: pick });
addEventListener('vf:ground', pick);

gsap.matchMedia().add(MOTION, () => {
  const hero = document.querySelector<HTMLElement>('.hero');
  if (hero) {
    const badge = hero.querySelector<HTMLElement>('.hero-icon');
    const words = [...hero.children].filter((el) => el !== badge);
    gsap.fromTo(hero.children, { autoAlpha: 0, y: 28 }, { autoAlpha: 1, y: 0, duration: 1, ease: EASE, stagger: 0.09, delay: 0.05 });

    // The words drift back and fade as the page moves on.
    gsap.fromTo(words, { opacity: 1, y: 0 }, {
      opacity: 0.15, y: -48, ease: 'none', immediateRender: false,
      scrollTrigger: { trigger: hero, start: 'top top', end: 'bottom top', scrub: 0.4 },
    });

    // The icon docks: it hangs back while the words go, then shrinks and flies into the menu
    // bar's icon, which takes over the moment it lands. Scrolling back undocks it.
    const icon = badge?.querySelector<SVGElement>('svg');
    const slot = document.querySelector<SVGElement>('#mb .mt.app svg');
    const brand = document.querySelector<HTMLElement>('#mb .app-name');
    if (badge && icon && slot && slot.getBoundingClientRect().width > 0) {
      const travel = () => Math.round(Math.min(420, innerHeight * 0.45));
      // Where the icon has to go, from layout alone (offsets ignore the entrance's transform):
      // the badge's place on the page and the slot's place in the fixed bar.
      const delta = () => {
        let top = 0, left = 0;
        for (let el: HTMLElement | null = badge; el; el = el.offsetParent as HTMLElement | null) { top += el.offsetTop; left += el.offsetLeft; }
        const s = slot.getBoundingClientRect();
        const bx = left + badge.offsetWidth / 2, by = top + badge.offsetHeight / 2;
        return { x: s.left + s.width / 2 - bx, y: s.top + s.height / 2 - (by - travel()) };
      };
      const shrink = Number(slot.getAttribute('width')) / Number(icon.getAttribute('width'));
      const tl = gsap.timeline({
        scrollTrigger: {
          trigger: document.body, start: 0, end: () => travel(), scrub: 0.3, invalidateOnRefresh: true,
        },
      });
      tl.fromTo(icon, { x: 0 }, { x: () => delta().x, ease: 'power2.inOut', duration: 1 }, 0)
        .fromTo(icon, { y: 0 }, { y: () => delta().y, ease: 'power1.in', duration: 1 }, 0)
        .fromTo(icon, { scale: 1 }, { scale: shrink, ease: 'power2.in', duration: 1 }, 0)
        .fromTo(badge, { '--glow': 1 }, { '--glow': 0, ease: 'none', duration: 0.6 }, 0.4)
        .to(icon, { opacity: 0, duration: 0.06, ease: 'none' }, 0.94)
        .fromTo(slot, { opacity: 0 }, { opacity: 1, duration: 0.06, ease: 'none' }, 0.94);
      // Until the icon lands, the name sits where the icon goes, so the bar never shows a hole;
      // it steps aside just as the icon arrives.
      if (brand) {
        const gap = parseFloat(getComputedStyle(slot.parentElement!).columnGap) || 8;
        tl.fromTo(brand, { x: -(Number(slot.getAttribute('width')) + gap) }, { x: 0, duration: 0.24, ease: 'power2.inOut' }, 0.72);
      }
    }
  }

  // Bookend: at the end of the page a copy of the menu bar icon drops out of the bar and lands
  // as the big icon above the final download, tied to the scroll like the hero's dock.
  const finalIcon = document.querySelector<SVGElement>('.final-inner > svg');
  const barIcon = document.querySelector<SVGElement>('#mb .mt.app svg');
  if (finalIcon && barIcon && barIcon.getBoundingClientRect().width > 0) {
    const holder = finalIcon.parentElement!;
    // Measured live on every update, so pins and late layout shifts above cannot skew it. The
    // icon stays hidden until the flight starts, so it never doubles the bar's icon up top.
    const ease = gsap.parseEase('power2.inOut');
    const k = Number(barIcon.getAttribute('width')) / Number(finalIcon.getAttribute('width'));
    const half = Number(finalIcon.getAttribute('height')) / 2;
    const render = (p: number) => {
      const e = ease(p), h = holder.getBoundingClientRect(), b = barIcon.getBoundingClientRect();
      const nx = h.left + h.width / 2, ny = h.top + half;
      gsap.set(finalIcon, {
        x: (b.left + b.width / 2 - nx) * (1 - e), y: (b.top + b.height / 2 - ny) * (1 - e),
        scale: k + (1 - k) * e, autoAlpha: p > 0 ? 1 : 0,
      });
    };
    ScrollTrigger.create({
      trigger: holder, start: 'top bottom', end: 'clamp(top 40%)',
      onUpdate: (self) => render(self.progress), onRefresh: (self) => render(self.progress),
    });
  }

  const items = gsap.utils.toArray<HTMLElement>(
    '.kt-head, .show .copy, .show .scene:not(#ascene), .ask-vis, .section-head, .cards > *, .extra, .table-box, .privacy-table, .faq, .final-inner > :not(svg)',
  );
  gsap.set(items, { autoAlpha: 0, y: 36 });
  ScrollTrigger.batch(items, {
    start: 'top 88%',
    once: true,
    // A jump (End key, a menu link) passes many at once: the ones already above the screen just
    // appear, and only what is in view rises in.
    onEnter: (batch) => {
      const passed = batch.filter((el) => el.getBoundingClientRect().bottom < 0);
      const rising = batch.filter((el) => !passed.includes(el));
      if (passed.length) gsap.set(passed, { clearProps: 'transform,opacity,visibility' });
      if (rising.length) gsap.to(rising, { autoAlpha: 1, y: 0, duration: 0.9, ease: EASE, stagger: 0.08, overwrite: true, clearProps: 'transform,opacity,visibility' });
    },
  });
});
