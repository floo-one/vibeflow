// Homepage motion: the hero settles in on load; as you scroll, its app icon shrinks and docks
// into the VibeFlow icon in the site's menu bar while the words drift back. The sections after
// it rise in once as they reach the screen. Reduced motion gets none of it; the CSS only hides
// the hero while this is known to run (.js and no-preference).
import { gsap, ScrollTrigger, EASE, MOTION } from './motion';

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
    }
  }

  const items = gsap.utils.toArray<HTMLElement>(
    '.kt-head, .show .copy, .show .scene, .ask-vis, .section-head, .cards > *, .extra, .table-box, .privacy-table, .faq, .final-inner',
  );
  gsap.set(items, { autoAlpha: 0, y: 36 });
  ScrollTrigger.batch(items, {
    start: 'top 88%',
    once: true,
    onEnter: (batch) =>
      gsap.to(batch, { autoAlpha: 1, y: 0, duration: 0.9, ease: EASE, stagger: 0.08, overwrite: true, clearProps: 'transform,opacity,visibility' }),
  });
});
