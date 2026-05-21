#!/usr/bin/env python3
"""
Tag consolidation script.

Applies a three-stage pass to every machine JSON in examples/machines/:

  Stage 1 – Remove internal state-code / function-name tags that leaked into
             workflowTags.  These are machine-internal identifiers, not
             taxonomy.  Patterns: ag-*, agriculture-<domain>-<detail>,
             built-space-well-<concept>-<detail> (when more specific than an
             established tag), and any tag that is a known state abbreviation.

  Stage 2 – Consolidate single/low-use tags to their canonical established
             equivalents using a longest-established-prefix rule plus an
             explicit semantic mapping table.

  Stage 3 – Fix the plural/singular inconsistency in the flat `tags` array:
             "dispatchable-agents" → "dispatchable-agent",
             "ai-triggers" → "ai-trigger".

Also renames `healthcare-operations*` workflowTags to `health-personal-operations*`
to stay consistent with the healthcare → health-personal domain rename.

Usage:
    python3 scripts/consolidate-tags.py [--dry-run]
"""

import json
import re
import sys
from pathlib import Path

DRY_RUN = '--dry-run' in sys.argv
MACHINES_DIR = Path(__file__).parent.parent / 'examples' / 'machines'

# ── Established workflowTags (≥10 occurrences in corpus pre-consolidation) ──
# Sorted longest-first so prefix matching is greedy / most-specific.
ESTABLISHED = sorted([
    'dispatchable-agent', 'ai-trigger',
    'public-health-system-transformation', 'logic-model', 'health-services-generated',
    'evaluation-plan', 'community-health-care-delivery', 'security',
    'well-operations', 'well-building-standard-operations', 'well-building-standard',
    'verification', 'transportation-generated', 'public-transit', 'occupant-health',
    'cleaning', 'built-space-well-generated', '24x7-operations', '100-bus-fleet',
    'rider-experience', 'nutrition', 'sleep', 'trademark', 'temperament-testing',
    'provisional-patent', 'productization', 'metabolic-health', 'lifestyle-psychiatry',
    'life-balance-generated', 'legal-services-generated', 'intellectual-property',
    'copyright', 'cgm', 'adolescent-psychiatry', 'cross-domain', 'public-safety',
    'law-enforcement', 'homelessness', 'health-and-human-services',
    'community-services-generated', 'city-services', 'upgrade-cycle',
    'regular-expression', 'operational-management', 'logical-infrastructure',
    'incident-response', 'digital-logic-infrastructure', 'digital-logic-generated',
    'data-center-generated', 'data-center-24x7-operations', 'asic-pattern',
    'agriculture-generated', 'kleene-plus', 'benefits-navigation-agent',
    'agriculture-indoor-grow-house', 'agriculture-aquaculture',
    'resource-dispatch-agent', 'quality-improvement-agent', 'public-health-nurse-agent',
    'partner-coordination-agent', 'measure-tracker', 'evaluation-analyst-agent',
    'community-health-worker-agent', 'care-coordinator-agent',
    'behavioral-health-crisis-agent', 'transportation', 'low-income', 'elder-care',
    'well-water-quality-agent', 'well-verification-agent', 'well-thermal-agent',
    'well-nourishment-agent', 'well-movement-agent', 'well-mind-policy-agent',
    'well-materials-cleaning-agent', 'well-light-agent', 'well-integrative-agent',
    'well-feedback-agent', 'well-community-hr-agent', 'well-air-quality-agent',
    'well-acoustic-agent', 'water-quality', 'victim-services-agent',
    'transportation-fleet-workforce-operations', 'transportation-fleet-vehicle-operations',
    'transportation-fleet-security-and-safety', 'transportation-fleet-rider-experience',
    'transportation-fleet-network-planning', 'transportation-fleet-finance-and-cost',
    'transportation-fleet-dispatch-and-flow-control', 'transportation-fleet-depot-operations',
    'transportation-fleet-customer-communications',
    'transportation-fleet-cleaning-and-sanitation',
    'transportation-fleet-charging-and-fueling', 'transportation-fleet-asset-infrastructure',
    'transit-workforce-agent', 'transit-vehicle-health-agent', 'transit-security-agent',
    'transit-rider-experience-agent', 'transit-planning-agent', 'transit-finance-agent',
    'transit-energy-agent', 'transit-dispatch-agent', 'transit-depot-agent',
    'transit-customer-comms-agent', 'transit-command-center-agent',
    'transit-cleaning-agent', 'transit-asset-agent', 'thermal-comfort',
    'testing-personalization-agent', 'stress-resilience-agent', 'sound-and-acoustics',
    'sleep-circadian-agent', 'public-safety-agent', 'psychiatric-care-agent',
    'product-counsel-agent', 'performance-verification', 'occupant-feedback',
    'nutrition-metabolic-agent', 'nourishment', 'movement-health-agent',
    'movement-and-fitness', 'mind-and-wellness-policy', 'materials-and-cleaning',
    'light-and-circadian', 'life-balance-whole-person-intake-and-goals',
    'life-balance-stress-resilience-and-psychotherapy',
    'life-balance-social-connection-and-harm-reduction',
    'life-balance-sleep-and-circadian-rhythm',
    'life-balance-nutrition-and-metabolic-health',
    'life-balance-movement-and-physical-health',
    'life-balance-medication-and-psychiatric-care', 'life-balance-intake-agent',
    'life-balance-command-agent', 'life-balance-adolescent-family-and-school',
    'legal-services-provisional-patent-filing', 'legal-services-portfolio-operations',
    'legal-services-individual-creator-services',
    'legal-services-filing-and-portal-operations',
    'legal-services-corporate-legal-services',
    'legal-services-commercialization-and-enforcement',
    'legal-services-ai-assisted-legal-operations', 'legal-ops-agent', 'ip-portfolio-agent',
    'integrative-planning', 'indoor-growing', 'housing-services-agent',
    'homeless-outreach-agent', 'health-services-workforce-development',
    'health-services-service-delivery-models', 'health-services-public-health-financing',
    'health-services-policy-implementation', 'health-services-performance-standards',
    'health-services-maternal-child-family-health',
    'health-services-learning-health-system',
    'health-services-interest-holder-alignment',
    'health-services-foundational-public-health-services',
    'health-services-evaluability-readiness',
    'health-services-environmental-health-response',
    'health-services-emergency-preparedness',
    'health-services-community-health-outcomes',
    'health-services-chronic-disease-prevention', 'health-services-care-coordination',
    'health-services-behavioral-health-integration', 'filing-portal-agent',
    'docketing-agent', 'design-and-biophilia', 'connection-harm-reduction-agent',
    'community-services-shelter-housing-and-supportive-services',
    'community-services-law-enforcement-and-public-safety',
    'community-services-homelessness-outreach',
    'community-services-health-and-human-services-intake',
    'community-services-courts-diversion-and-victim-services',
    'community-services-city-service-operations',
    'community-services-benefits-and-eligibility',
    'community-services-behavioral-health-and-crisis',
    'community-intake-agent', 'community-command-agent', 'community-and-hr',
    'city-operations-agent', 'built-space-well-water-quality',
    'built-space-well-thermal-comfort', 'built-space-well-sound-and-acoustics',
    'built-space-well-performance-verification', 'built-space-well-occupant-feedback',
    'built-space-well-nourishment', 'built-space-well-movement-and-fitness',
    'built-space-well-mind-and-wellness-policy',
    'built-space-well-materials-and-cleaning', 'built-space-well-light-and-circadian',
    'built-space-well-integrative-planning', 'built-space-well-design-and-biophilia',
    'built-space-well-community-and-hr', 'built-space-well-air-quality',
    'built-space-command-agent', 'behavioral-crisis-agent', 'attorney-review-agent',
    'air-quality', 'adolescent-family-agent',
    # Promoted from low-use (clear established patterns)
    'flip-flop', 'trigger', 'service-delivery', 'data-center',
    'growhouse-irrigation-agent', 'growhouse-ipm-agent', 'growhouse-crop-steering-agent',
    'growhouse-climate-agent', 'dc-storage-agent', 'dc-sre-agent', 'dc-security-agent',
    'dc-power-agent', 'dc-network-agent', 'dc-facilities-agent', 'dc-cooling-agent',
    'dc-compute-agent', 'dc-change-manager-agent', 'aquaculture-water-quality-agent',
    'aquaculture-health-agent', 'ai-workload', 'chronic-disease', 'wellness',
    'social-services', 'mental-health', 'medication', 'intake', 'food-insecurity',
    'case-management', 'benefits-eligibility', 'anomaly-detection',
], key=len, reverse=True)

ESTABLISHED_SET = set(ESTABLISHED)

# ── Stage 1: Tags to REMOVE entirely ──────────────────────────────────────────
# Internal machine state abbreviations and function names that are not taxonomy.
REMOVE_PATTERNS = [
    # ag-* internal function labels
    re.compile(r'^ag-[a-z]'),
    # agx0001-style agriculture machine state codes (no dash, digit suffix)
    re.compile(r'^agx\d+$'),
    # Other machine-code state abbreviations: AGX, BSX, CSX, DCX, DLX, HSPH,
    # LBL, LSX, TFX followed by digits.  These are filename-derived identifiers
    # not taxonomy.
    re.compile(r'^(?:agx|bsx|csx|dcx|dlx|hsph|lbl|lsx|tfx)\d+$'),
    # agriculture-<domain>-<specific-detail> compound tags with 3+ segments.
    # The top-level agriculture-aquaculture and agriculture-indoor-grow-house
    # are KEPT (they're established); only the over-specific variants are removed.
    re.compile(r'^agriculture-(?:aquaculture|indoor-grow-house|atmospheric|nutrient)-\w+-\w+'),
    # State-code abbreviations: short 4-letter prefix + state name (ai*, dc*, etc.)
    re.compile(r'^(?:aicr|aihr|aimw|aipe|aism|aiwc|aict|air)-'),
]

REMOVE_EXACT = {
    # Redundant / meaningless in taxonomy context
    'offset', 'input', 'output', 'length', 'sequences', 'family', 'tagging',
    # Overly broad noise words that add no classification signal
    'activity',
}

# ── Stage 2: Explicit semantic mapping ───────────────────────────────────────
# For cases where the prefix rule gives the wrong answer or no match exists.
# Maps single/low-use tag → canonical established tag.
EXPLICIT_MAP: dict[str, str] = {
    # healthcare-operations → health-personal-operations (domain rename follow-on)
    'healthcare-operations': 'health-personal-operations',
    # Compound tags → simpler established equivalents
    'nutrition-and-metabolic-health': 'nutrition-metabolic-agent',
    'law-enforcement-and-public-safety': 'law-enforcement',
    'medication-and-psychiatric-care': 'psychiatric-care-agent',
    'healthcare-operations-assisted-living-daily-care': 'health-personal-operations',
    'healthcare-operations-resident-wellness-assessment': 'health-personal-operations',
    'healthcare-operations-new-patient-inflow': 'health-personal-operations',
    'healthcare-operations-care-transition-workflow': 'health-personal-operations',
    'healthcare-operations-patient-wellness-tracking': 'health-personal-operations',
    # Near-duplicate concept variants
    'continuous': 'anomaly-detection',
    'cooling': 'thermal-comfort',
    'chronic-pain': 'chronic-disease',
    'patient-wellness': 'wellness',
    'nutrient-solution': 'nutrition',
    'in-home-monitoring': 'anomaly-detection',
    'enrollment': 'intake',
    'intake-assessment': 'intake',
    'aging-services-intake': 'intake',
    'daily-care': 'elder-care',
    'fall-detection': 'anomaly-detection',
    'binary': 'digital-logic-generated',
    'network': 'logical-infrastructure',
    'humidity': 'thermal-comfort',
    'harvest': 'agriculture-generated',
    'climate-control': 'thermal-comfort',
    'care-transition': 'community-services-health-and-human-services-intake',
    'snap': 'benefits-eligibility',
    'wic': 'benefits-eligibility',
    'social-services': 'community-services-generated',
    'safety': 'security',
    'trend': 'anomaly-detection',
    'ai': 'ai-trigger',
    'new-patient-inflow': 'health-personal-operations',
    'age-cohort': 'adolescent-psychiatry',
    'adolescent': 'adolescent-psychiatry',
    'adolescent-guardian-alignment': 'life-balance-adolescent-family-and-school',
    'adolescent-mental-health-monitor': 'life-balance-adolescent-family-and-school',
    'adolescent-safety-signal': 'life-balance-adolescent-family-and-school',
    'adolescent-sleep-school-fit': 'life-balance-sleep-and-circadian-rhythm',
    'adolescent-sports-balance': 'life-balance-movement-and-physical-health',
    'adverse-effect-watch': 'psychiatric-care-agent',
}

# ── Stage 3: Plural/singular fix in flat `tags` array ──────────────────────
PLURAL_FIXES = {
    'dispatchable-agents': 'dispatchable-agent',
    'ai-triggers': 'ai-trigger',
}


def longest_established_prefix(tag: str) -> str | None:
    """Return the longest established tag that is a prefix of `tag` (with a dash separator)."""
    if tag in ESTABLISHED_SET:
        return tag
    for est in ESTABLISHED:  # sorted longest-first
        if tag.startswith(est + '-'):
            return est
    return None


def should_remove(tag: str) -> bool:
    if tag in REMOVE_EXACT:
        return True
    return any(p.match(tag) for p in REMOVE_PATTERNS)


def consolidate_tag(tag: str) -> str | None:
    """Return the canonical tag for `tag`, or None to drop it."""
    if should_remove(tag):
        return None
    if tag in EXPLICIT_MAP:
        return EXPLICIT_MAP[tag]
    prefix = longest_established_prefix(tag)
    if prefix and prefix != tag:
        return prefix
    # Keep as-is (either established or no mapping found)
    return tag


def dedupe_preserve_order(lst: list) -> list:
    seen = set()
    out = []
    for x in lst:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def process_file(path: Path) -> tuple[bool, dict]:
    data = json.loads(path.read_text())
    machine = data.get('machine', {})
    meta = machine.get('metadata', {})
    tagging = meta.get('tagging', {})
    changed = False

    # ── workflowTags consolidation ──────────────────────────────────────────
    wf = tagging.get('workflowTags', [])
    if wf:
        new_wf = []
        for tag in wf:
            mapped = consolidate_tag(tag)
            if mapped is None:
                changed = True          # tag dropped
            elif mapped != tag:
                new_wf.append(mapped)
                changed = True
            else:
                new_wf.append(tag)
        new_wf = dedupe_preserve_order(new_wf)
        if new_wf != wf:
            tagging['workflowTags'] = new_wf
            changed = True

    # ── flat tags array: plural fix ────────────────────────────────────────
    flat_tags = meta.get('tags', [])
    if flat_tags:
        new_flat = [PLURAL_FIXES.get(t, t) for t in flat_tags]
        new_flat = dedupe_preserve_order(new_flat)
        if new_flat != flat_tags:
            meta['tags'] = new_flat
            changed = True

    return changed, data


def main():
    files = sorted(MACHINES_DIR.glob('*.json'))
    changed_count = 0
    total_removed = 0
    total_consolidated = 0

    for path in files:
        try:
            changed, data = process_file(path)
        except Exception as e:
            print(f'ERROR {path.name}: {e}')
            continue

        if changed:
            changed_count += 1
            if not DRY_RUN:
                path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')

    mode = 'DRY RUN — ' if DRY_RUN else ''
    print(f'{mode}Updated {changed_count}/{len(files)} machine files')


if __name__ == '__main__':
    main()
