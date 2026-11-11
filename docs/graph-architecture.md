# The graph view: design

This is the draft the graph view in the app (`lib/graph/`, `lib/screens/graph_view.dart`) is built from. It starts from
what OpenKnowledgeBase (`~/Documents/OpenKnowledgeBase`, Python) does and says what was changed and why.

## What OpenKnowledgeBase does

1. A document is cut into chunks; an LLM turns each chunk into *knowledge leaves* (title of 2-5 words, a tag - Fact,
   Explanation, Data, Method, Result, Claim -, keywords, a standalone sentence, the excerpt and where it is).
2. A leaf is embedded (its keywords only) and put in a tree of `KnowledgeNode`s. Every node owns a FAISS index.
3. After each ingest the tree is *sorted* again: distance-threshold clustering that gets stricter with depth, an LLM
   that names and routes the clusters, merging of nodes whose centroids are alike (> 0.95), nesting (> 0.9), removal of
   lonely nodes, and "lateral links" between nodes whose centroids are alike (> 0.9) but that are not kin.
4. The tree is drawn with igraph (Reingold-Tilford, circular layout) in a GTK drawing area, with pan and zoom.

## What is not good about it

* **The graph is mutable state.** Nodes, indexes and links are changed in place by one long pass; a failure half-way
  leaves a tree nobody can reason about, and any change means sorting again from the root.
* **The LLM sits in the middle of the structure** (naming, routing, consolidating). That makes the shape of the graph
  non-deterministic and slow, and impossible without a model.
* **Everything is recomputed**, nothing is kept per source: one changed paragraph means extracting its facts again,
  and the layout starts from nothing.
* **One tree, one idea of closeness.** A tree has to put a fact in exactly one place; the real structure (a fact that
  belongs to two topics, a note that points at another) is only approximated by the "lateral" links.
* The layout is computed while drawing and the drawing is tied to one toolkit.

## The design

Four layers, each a pure step over the one before, with what is expensive kept in the database:

```
 notes ──▶ 1 extraction ──▶ 2 vectors ──▶ 3 structure ──▶ 4 layout ──▶ view
          (facts, kept)    (kept)        (pure function)   (isolate, kept)
```

1. **Extraction** (`fact_extractor.dart`). Per note, only when the note's text changed (hash and prompt version kept in
   `fact_state`). The AI provider that is chosen (the same choice as everywhere: on the device, or a service; the graph
   screen shows who writes and has the switch) reads the note in windows - about 800 tokens for a small model, more
   for a service, cut at pages (slides) - with OpenKnowledgeBase's extraction prompt: abstract definitions,
   mechanisms, causes, rules and categories only; no fluff, situational examples or pointers to other slides; a title in
   the form "Parent Concept: Specific Mechanism"; a sentence that stands on its own (no pronouns, no "the slide says").
   The answer is one `Title | Tag | Sentence | keywords` line per fact (small models keep to lines better than JSON).
   A window with no usable line is asked again (twice), and a fact that still leans on its context ("It ...", "In this
   example ...") or repeats another is dropped. **Without a model there are no facts**: pieces of slides are not facts,
   and the person is told to set a model up. Facts are rows (`facts`), so they can later be listed, searched and edited.
2. **Vectors**. A fact is embedded by its keywords (its title when it has none), as OpenKnowledgeBase does, by the sentence model that is installed; without one a
   hashed bag of words stands in (`LexicalEmbedder`), so the graph is lexical rather than missing. Notes use the
   vectors that the sorting of notes keeps (`note_embeddings`).
3. **Structure** (`graph_builder.dart`, a pure function of nodes and vectors, so it is testable and repeatable):
   * *edges*: each node is joined to its few nearest neighbours above a similarity bar (mutual and strong ones weigh
     more); a note that links to another note (`note:<id>` in a text) is an explicit edge that always shows; two notes that cite the same source (`[@key]`, see the citations) are joined by an edge of their own (`cites`) that also always shows, the stronger the more sources they share - a source that more than 12 notes cite joins nobody;
   * *communities* (topics): label propagation over the weighted edges in a fixed order, small ones folded into
     the nearest big one - no tree, so a fact can sit between two topics through its edges;
   * *names* of a topic: its most telling words (TF-IDF over the titles and keywords of the topic against all);
   * *topic hubs*: one node per topic with at least 3 members, joined to them; *note hubs* (optional): a note joined
     to its facts. This gives the hierarchy OpenKnowledgeBase has (topic - fact, note - fact) without moving
     anything around.
4. **Layout** (`graph_layout.dart`). Force-directed (Fruchterman-Reingold) with repulsion limited to a grid of
   neighbouring cells, so it is O(n) per step and runs in an isolate; it starts from a seed where each topic has its
   own place on a spiral, so it settles in few steps, and the result (positions) is kept with the graph.

A built graph is kept (`saved_graphs`: a name, the kind - notes or facts -, the folder it was made of, when, and the graph with its
layout) and the view shows the kept graphs as **tabs**, so one can switch between them without making them again. **A graph is never
made on its own**: the "+" button (or "Generate graph" while there is none) asks for the kind, the notes to use and the sliders, runs the
steps (with progress and a stop button) and keeps the result as a new tab, named after its kind and folder ("Facts: All notes", with a
number when that name is taken). The menu of the tab in front renames it, makes it again in place (same kind and folder, newer picture,
same name) or deletes it (the notes and facts stay). A stopped or failed run keeps what there was. The tab in front is remembered while
the app runs; what was chosen or filtered in a graph starts again when another tab comes to the front. Version 50 databases had one
graph per kind (`graph_snapshots`): the migration turns each into a tab named "Facts" / "Notes".

**Between devices.** A kept graph goes by a `uid` that is the same on every device of the profile (the tab's number is only this
device's) and has an `updated_at` (made, made again or renamed). It travels with the rest of the profile sync (see
[profile-sync.md](profile-sync.md)), over a direct connection and through a cloud folder alike: the manifest has a line for each graph
(`SyncGraph`: uid, name, kind, folder, when), the picture is asked for only when the other device's line is newer, and a removed graph
leaves a tombstone (`graph` in `sync_tombstones`) so that it goes from the other devices too and does not come back. A graph is taken
over **as a whole and the newer wins** (a tie goes to the lower device id); unlike a note no copy of the older one is kept, because a graph
can be made again. So a rename on one device and a new picture on another at nearly the same time end as one of the two. A picture that
cannot be read, or whose kind is not the one its line says, is not taken over. The pictures are never part of a share (a share's library
has no graphs), and, like notes, travel sealed. A graph made, renamed or removed here tells the sync (`graph:<uid>` on
`NoteRepository.changes`), one the sync took in does not (no echo). The tab list is read again whenever the view opens; a graph that
arrives while the view is open shows the next time it is opened.

**Export.** The menu of a tab saves the whole graph (what the filter hides is included) as a file (`lib/graph/graph_export.dart`):

* *JSON*: `{format: "notation-graph", version: 1, name, kind, madeAt, embedder, topics: [{id, label, size}], nodes: [{id, type, label,
  detail?, tag?, topic, note?: {id, title, page}, x, y, size}], edges: [{source, target, type, weight}]}`; an edge names its nodes by
  `id`, `page` counts from 1, `x`/`y`/`size` are the layout the app drew.
* *SVG*: a picture on white with the lines (a contradiction red and dashed, links and shared sources stronger), the nodes in the colour of
  their topic (a note among facts a square, a topic hub with a ring), the names of topics and notes beside them (and of the facts while
  there are at most 300 nodes), a list of the topics to the right, and each node's text as a `<title>` that a browser shows on hover.

Extraction, the heavy part, only touches notes that changed since the last time.

Two modes, because they answer two questions:

* **Notes**: one node per note, edges from similarity and links, colour by topic (or folder).
* **Facts**: one node per extracted fact, topic hubs and optionally note hubs; selecting a node shows the sentence and the
  note and page it came from, and opens the note there.

## Layout, making a graph again, and the build step

* *Build*: the similarity of all pairs (the one quadratic step, 96 % of the build) runs over one array of the vectors (zero-padded to a
  multiple of four), tile by tile so that a tile stays in the cache, four numbers at a time (`Float32x4` on native; the browser build keeps
  a scalar loop because the types are emulated there). 6000 nodes of 384 numbers: 10 s before, 2.7 s after (JIT, synthetic vectors).
  `test/graph_nearest_test.dart` checks the edges against a loop over all pairs.
* *Layout* (`graph_layout.dart`): stops when the nodes hardly move, then pushes apart dots that touch (`test/graph_layout_test.dart`).
  A graph made again starts from the places of the old one by node id (`placesOf` / `start`): new nodes begin among their placed
  neighbours, the run is cool and short, and a graph that shares less than half of its nodes with the old one is laid out afresh.

## The graph library, earlier pictures, comparing

When a graph is made again (or a newer picture from another device takes its place) the picture it had goes into `graph_versions` (schema
57; the newest five per graph, `KnowledgeRepository.keptVersions`; **this device only, not synced**; removed with the graph). The graph
library (`lib/screens/graph_library.dart`, the button in the app bar) lists every graph with its pictures: open, rename, delete a graph;
compare a picture with the graph in front, bring a picture back (the current one takes its place in the list, and the graph counts as
changed, so the other devices take it over), delete a picture.

`graph_diff.dart` (pure): the nodes of two graphs are told apart by id, so graphs made of the same notes line up (a fact's id is its row;
re-extracting a changed note gives it new rows, which is why changed notes show as gone + new). It gives new / changed (title or text) /
gone nodes, links that appeared or went between nodes both graphs have, and topics that came or went by name. Topic hubs and their
`member` / `source` lines are left out (their ids are numbers of the run). The view shows a bar ("Compared with ...: n new, n gone, n
changed", with a sheet that lists them), rings new nodes green and changed ones amber, and shows it by itself after "Generate again". The tab menu's "Compare
with..." offers the earlier pictures and the other graphs of the same kind.

## Naming topics, and the sentence model

A topic is named by its most telling words; the generate dialog can instead have the AI model name them (`topic_namer.dart`: one request
for up to 20 topics, "number | name" lines, titles of the 8 best joined nodes as the evidence; only when a model is ready). The model never
decides which node is in which topic, so the graph is the same with or without it. A name is marked in the picture (`GraphCluster.named`);
when a graph is made again a topic whose members overlap (Jaccard >= 0.6) with a named topic of the old picture keeps that name and costs
no request. A failed request leaves the words and says why in the notice. Graphs made without the sentence model (`embedder == 'lexical'`)
show a bar saying topics follow shared words; the generate dialog says so before making one.

## Is it possible in Flutter?

Yes. Nothing here needs a native toolkit: the layout is plain Dart in an isolate; drawing is a `CustomPainter` under an
`InteractiveViewer` (pan, pinch, wheel zoom), with edges and labels left out when they are off screen or too small to
read, and a node found for a tap through the same grid the layout used. A graph of a few thousand nodes draws in one
frame; beyond that the view draws only the strongest edges. That is why the design keeps layout and structure out of the
widget.

## Filters

The filter button (top right of the picture, with a badge for the settings in use) narrows what is *shown*; nothing is made again
and the layout stays. `GraphFilter` (`lib/graph/graph_filter.dart`, plain Dart) leaves out nodes and lines:

* *Kinds of fact* (Definition, Data...) and *notes* (a topic stays while one of its nodes does).
* *Lines*: by kind (similarity, links written in notes, same source cited) and a weakest similarity.
* *Hide topics and notes as nodes* (the facts alone), and *hide nodes without lines*. A topic with no node left to join always goes.

Search, the topic list and the neighbours of a chosen node work on what is left. The filter starts again with another mode or a new graph.

## Study tools

Taken from OpenKnowledgeBase's flashcard, question, grade and search prompts, on top of the facts (facts mode only). Selecting a topic (or
nothing, for all facts) offers **Flashcards**, **Quiz** and **Ask** (`lib/graph/study.dart`, `lib/screens/graph_study.dart`):

* *Flashcards*: the facts go to the model in batches of 10 with the assistant's flashcard prompt; the cards are studied with the same deck
  (`FlashcardDeck`, `DeckView`) as the assistant's.
* *Quiz*: comprehension questions with a reference answer. The student answers in words, the model grades it (score 1-10, correct, feedback;
  the idea counts, not the wording). As in OpenKnowledgeBase a grade raises the weight of the question by half of the score, a correct answer
  masters it, and the weakest question that is not mastered comes next.
* *Ask*: a question answered from the facts alone (the ten that fit best by their words, or those of the topic); when they do not say, the
  model says so.

Nothing is kept: cards and quizzes are made when asked for. They need a model that is ready; the facts are what is sent, not the notes.
