// The Ask back section: a page from a book, a phrase selected, a question asked out loud and a
// short spoken answer, then a follow-up. Each visitor sees one source at random, never the one
// their browser showed last time; the authors are never listed. Page texts and answers are our
// own wording of each author's idea, not quotations.

export interface AskSource {
  title: string;
  author: string;
  pre: string;
  sel: string;
  post: string;
  qa: { q: string; a: string }[];
}

export const ASK_SOURCES: AskSource[] = [
  { title: 'The Beginning of Infinity', author: 'David Deutsch',
    pre: 'Deutsch’s claim is that all progress comes from one thing: the search for good explanations. A bad explanation can be bent to fit any outcome, so it tells us nothing. Good explanations are ',
    sel: 'hard to vary', post: ': every detail does work, and you can’t change one without breaking the whole.',
    qa: [
      { q: 'What does that mean?', a: 'Every part of a good explanation is load-bearing. Change a detail and it stops working. A myth can swap one god for another and still “explain” the same thing, which is exactly why it explains nothing.' },
      { q: 'Give me an example.', a: 'Seasons. “A goddess is sad, so it’s winter” survives any rewrite. “Earth’s axis is tilted” doesn’t: change the tilt and you predict the wrong seasons, in the wrong hemispheres.' },
    ] },
  { title: 'The Almanack of Naval Ravikant', author: 'Eric Jorgenson',
    pre: 'Naval’s path to wealth starts with ',
    sel: 'specific knowledge', post: ': what you know because you were curious, not because someone taught you. Add leverage, like code or media, and put your own name on the result.',
    qa: [
      { q: 'What does that mean?', a: 'Know-how that grew out of your own curiosity, so nobody can be trained to replace you. If a course can teach it, someone cheaper will learn it too.' },
      { q: 'How do I find mine?', a: 'Look at what feels like play to you but looks like work to others. That’s usually where it is.' },
    ] },
  { title: 'Direct Truth', author: 'Kapil Gupta',
    pre: 'Kapil Gupta distrusts every method. Techniques, routines and habits keep you busy, he argues, without changing anything. A problem doesn’t need to be managed; it ends when it is ',
    sel: 'seen completely', post: '.',
    qa: [
      { q: 'What does that mean?', a: 'Instead of a trick to cope with a problem, you look at it until you understand exactly how you keep creating it. Once that’s clear, there’s nothing left to manage.' },
      { q: 'Isn’t a method useful, though?', a: 'In his view, a method lets you put off the looking. You practise the technique and never face the thing itself.' },
    ] },
  { title: 'Freedom from the Known', author: 'J. Krishnamurti',
    pre: 'Krishnamurti asks you to look at fear without running from it, naming it or explaining it away. Watch it that way, he says, and you find that ',
    sel: 'the observer is the observed', post: ': there is no separate you standing outside the fear.',
    qa: [
      { q: 'What does that mean?', a: 'It feels like there’s a “you” who has the fear and could step outside to fix it. He means the one looking is made of the same thoughts as the fear. There’s no outsider to do the fixing.' },
      { q: 'So what do I do?', a: 'Nothing, in his sense. You watch it fully, without judging. That kind of attention is the change.' },
    ] },
  { title: 'Siddhartha', author: 'Hermann Hesse',
    pre: 'Near the end of the book, Siddhartha, now an old ferryman, tells his friend Govinda that ',
    sel: 'wisdom cannot be passed on', post: '. Knowledge can be taught; wisdom has to be found, by each person, on their own.',
    qa: [
      { q: 'What does that mean?', a: 'You can hand someone facts, but not the understanding that comes from living through something. Siddhartha only grew wise through his own mistakes, not by following a teacher.' },
      { q: 'Then why read books at all?', a: 'They can point the way. In the story, the river teaches Siddhartha more than any teacher did, because he listened to it himself.' },
    ] },
];
