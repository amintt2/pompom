"""Couche de decision : field_kind (quel genre de champ) + best_candidate (quel texte copie coller).

Une seule interface, deux strategies (mesurees toutes les deux, voir bench.py) :
  - "hybrid" (defaut) : regles (< 1 ms) quand c'est evident ; tetes stuntd seulement si c'est ambigu
    (sorte de champ incertaine, ou plusieurs TYPES de textes copies aussi plausibles pour un champ libre) ;
  - "heads" : les tetes stuntd decident tout (les regles ne servent plus qu'aux mots de passe et au typage
    des textes copies).
Les tetes ne generent rien : ce sont des classifieurs (choix parmi des etiquettes fixes).
Sans tetes (demarrage, fichiers absents, erreur), les regles seules repondent.
"""

from __future__ import annotations

import time
from dataclasses import asdict, dataclass

from . import rules
from .heads import SITE_FIELD, SITE_TEXT, HeadAnswer, describe_field, text_kind_input

PLAUSIBLE = 0.5  # compatibilite minimale d'un texte avec un champ libre
TIE = 0.05


@dataclass
class Suggestion:
    kind: str
    index: int  # -1 = rien a proposer
    confidence: float
    label_fr: str
    kind_source: str  # rules | head | rules-fallback
    pick_source: str  # rules | head | none
    candidate_types: list[str]
    ms: float
    model_ms: float = 0.0
    skip: str = ""

    def to_dict(self) -> dict:
        return asdict(self)


class Decider:
    """Interface stable : suggest(field, candidates) -> Suggestion ; field_kind(field) ; choose(...)."""

    def __init__(self, heads=None, kind_threshold: float = 0.85, mode: str = "hybrid",
                 secret_guard: bool = True, semantic_secret: bool = True) -> None:
        self.heads = heads
        self.kind_threshold = kind_threshold
        self.mode = mode
        self.secret_guard = secret_guard  # False = comportement d'avant eval_v2 (mesure de reference)
        self.semantic_secret = semantic_secret  # + garde de l'encodeur (tete « secret ») si elle existe
        self.on_use = None  # rappel du service : « j'aurais besoin du modele » (chargement a la demande)

    def ready(self, site: str = SITE_FIELD) -> bool:
        if self.on_use is not None:
            self.on_use()
        h = self.heads
        return h is not None and h.has(site)

    # ---------------------------------------------------------------- field_kind
    def field_kind(self, field: dict) -> tuple[str, float, str, float]:
        """(sorte, confiance, source, ms_modele)."""
        g = rules.guess_field_kind(field)
        use_head = self.ready(SITE_FIELD) and (self.mode == "heads" or g.confidence < self.kind_threshold)
        if not use_head:
            return g.kind, g.confidence, ("rules" if g.confidence >= self.kind_threshold else "rules-fallback"), 0.0
        try:
            a = self.heads.ask(SITE_FIELD, describe_field(field))  # type: ignore[union-attr]
        except Exception:
            return g.kind, g.confidence, "rules-fallback", 0.0
        if self.mode == "hybrid" and not a.confident:
            # la tete n'est pas assez sure (seuil fixe a l'entrainement par stuntd) : on garde les regles
            return g.kind, g.confidence, "rules-fallback", a.ms
        conf = a.confidence
        if g.confidence >= 0.5 and g.kind == a.label:
            conf = max(conf, 0.9)  # les regles avaient le meme indice
        return a.label, conf, "head", a.ms

    # ---------------------------------------------------------------- best_candidate
    def _ask_text_kind(self, field: dict, kind: str, types: list[str], allowed: list[str]) -> HeadAnswer:
        return self.heads.ask(SITE_TEXT, text_kind_input(kind, field, types), allowed=allowed)  # type: ignore[union-attr]

    def best_candidate(self, field: dict, kind: str, candidates: list[str], types: list[str]) -> tuple[int, float, str, float]:
        """(index ou -1, confiance, source, ms_modele). candidates : du plus recent au plus ancien."""
        if not candidates:
            return -1, 1.0, "none", 0.0
        newest: dict[str, int] = {}
        for i, t in enumerate(types):
            newest.setdefault(t, i)
        if self.mode == "heads" and self.ready(SITE_TEXT):
            try:
                a = self._ask_text_kind(field, kind, types, list(newest) + ["none"])
                return (-1 if a.label == "none" else newest[a.label]), a.confidence, "head", a.ms
            except Exception:
                pass
        compat = rules.COMPAT.get(kind, {})
        scored = [(compat.get(t, 0.0), -i, i) for i, t in enumerate(types)]
        scored.sort(reverse=True)
        best_score = scored[0][0]
        if best_score <= 0.0:
            return -1, 0.9, "rules", 0.0
        if kind in rules.STRICT_KINDS:
            return scored[0][2], 0.95 * best_score, "rules", 0.0  # le plus recent texte du bon type
        # Champ libre (recherche, message, code...) : on garde les textes vraiment plausibles.
        plausible = [x for x in scored if x[0] >= PLAUSIBLE]
        if not plausible:
            return -1, 0.8, "rules", 0.0
        top = plausible[0][0]
        tied = sorted(i for sc, _, i in plausible if sc >= top - TIE)
        tied_types = list(dict.fromkeys(types[i] for i in tied))
        if len(tied_types) == 1:
            return tied[0], 0.5 + 0.4 * top, "rules", 0.0  # un seul type en tete : le plus recent
        # Egalite entre types differents (ex. recherche : une adresse ou une phrase ?) : la tete text_kind
        # choisit le TYPE voulu selon l'appli/la fenetre, puis on prend le plus recent texte de ce type.
        if not self.ready(SITE_TEXT):
            return tied[0], 0.5, "rules", 0.0
        try:
            a = self._ask_text_kind(field, kind, types, tied_types)
        except Exception:
            return tied[0], 0.5, "rules", 0.0
        if not a.confident:
            return tied[0], 0.5, "rules-fallback", a.ms
        return newest[a.label], a.confidence, "head", a.ms

    # ---------------------------------------------------------------- tout
    def suggest(self, field: dict, candidates: list[str]) -> Suggestion:
        t0 = time.perf_counter()
        if not field or field.get("skip") or field.get("is_password"):
            return Suggestion("other", -1, 1.0, "", "rules", "none", [], 0.0,
                              skip=str(field.get("skip", "password") if field else "no_field"))
        if self.secret_guard and rules.is_secret_field(field):
            # champ secret non marque comme mot de passe (code PIN, code SMS, carte, cle d'API...) : rien
            return Suggestion("other", -1, 1.0, "", "rules", "none", [], 0.0, skip="secret")
        types = [rules.content_type(c) for c in candidates]
        kind, kconf, ksrc, kms = self.field_kind(field)
        idx, pconf, psrc, pms = self.best_candidate(field, kind, candidates, types)
        # seulement si le modele a deja lu ce champ (regles pas sures) : son vecteur est en cache -> ~0 ms de plus ;
        # un champ que les regles reconnaissent avec certitude (« Adresse e-mail »...) n'est pas un secret
        if (idx >= 0 and ksrc != "rules" and self.secret_guard and self.semantic_secret and self.heads is not None
                and hasattr(self.heads, "is_secret")):
            # garde semantique de l'encodeur (si sa tete existe), seulement quand on allait proposer un texte
            try:
                if self.heads.is_secret(field):
                    return Suggestion("other", -1, 1.0, "", "head", "none", [], 0.0, skip="secret")
            except Exception:
                pass
        conf = kconf * pconf if idx >= 0 else kconf
        label = rules.label_fr(kind, candidates[idx]) if idx >= 0 else ""
        return Suggestion(kind, idx, round(conf, 3), label, ksrc, psrc, types,
                          round((time.perf_counter() - t0) * 1000.0, 2), round(kms + pms, 2))

    # ---------------------------------------------------------------- generique (jeu, etc.)
    def choose(self, question: str, options: list[str], context: str = "") -> HeadAnswer:
        """Choix generique parmi des options (ex. action du compagnon), en zero-shot Laya.
        Leve RuntimeError si le modele n'est pas charge."""
        if self.heads is None:
            raise RuntimeError("model-not-ready")
        return self.heads.choose(question, options, context)
