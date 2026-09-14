"""Visualisation helpers for the PowSyBl Open Load Flow Knitro solver.

The ``RELAXED`` and ``USE_REACTIVE_LIMITS`` Knitro solvers turn the load flow
into an optimisation problem: instead of failing when the power flow equations
cannot be satisfied, they relax them with *slack variables* and minimise the
resulting violations. A non-zero slack therefore points at *where* the network
is infeasible, and of *which* nature the infeasibility is (P, Q or V).

This module contains three helpers:

* :func:`calculate_dc_losses` -- estimates the network active losses from a DC
  load flow, to be passed to the solver through the ``losses`` parameter.
* :func:`compute_slack_info` -- joins the CSV exported by the solver
  (``exportSolution`` parameter) onto the network buses.
* :func:`nad_explorer_with_slack` -- a drop-in replacement for
  ``pypowsybl_jupyter.nad_explorer`` that adds a slack legend, a slack filter
  and a per-bus slack detail panel next to the network area diagram.
"""

import math

import pandas as pd
import ipywidgets as widgets
from pandas import DataFrame
from pypowsybl.network import Network, NadParameters
from pypowsybl_jupyter.nadwidget import display_nad, update_nad

try:  # NadProfile is only available in recent pypowsybl versions
    from pypowsybl.network import NadProfile
except ImportError:  # pragma: no cover
    NadProfile = None

#: Colour code used both in the legend and in the per-bus detail panel.
SLACK_EMOJI = {"P": "🔴", "Q": "🔵", "V": "🟢"}
NO_SLACK_EMOJI = "⚪"


def calculate_dc_losses(dc_network: Network, voltage_levels: DataFrame) -> float:
    """Estimate the total active losses (MW) of a network solved in DC.

    The DC load flow neglects losses, so they are re-estimated a posteriori as
    ``r * (p1 / vnom) ** 2`` on every line. The result is meant to be fed to the
    Knitro ``losses`` parameter, which uses it to weight the objective function.

    Args:
        dc_network: a network on which ``pypowsybl.loadflow.run_dc`` has been run.
        voltage_levels: the ``get_voltage_levels()`` dataframe of that network.

    Returns:
        The estimated total active losses, in MW.
    """
    lines = dc_network.get_lines()
    total_losses = 0.0

    for _, line in lines.iterrows():
        r = line["r"]
        p1 = line["p1"]
        if r == 0 or math.isnan(p1):
            continue
        vnom = voltage_levels.loc[line["voltage_level1_id"], "nominal_v"]
        total_losses += r * (abs(p1) ** 2) / (vnom**2)

    return total_losses


def compute_slack_info(
    network: Network, slack_export: DataFrame, outerloop: int = 0
) -> DataFrame:
    """Join the solver slack export onto every bus of the network.

    The CSV exported by the solver only lists the buses carrying a slack. To be
    able to tell "no slack here" from "bus not in the export", it is left-joined
    onto the full bus-breaker view of the network.

    Args:
        network: the network solved with the Knitro solver.
        slack_export: the dataframe read from the ``exportSolution`` CSV.
        outerloop: index of the outer loop iteration to keep. The solver exports
            one block of rows per outer loop iteration; ``0`` is the first one.

    Returns:
        One row per (bus, slack) pair, with an extra boolean ``has_slack``
        column. Buses without any slack appear once with ``has_slack=False``.
    """
    buses = network.get_bus_breaker_view_buses()
    if "bus_id" not in buses.columns:
        raise RuntimeError(
            "get_bus_breaker_view_buses() did not return a 'bus_id' column "
            f"(got {list(buses.columns)}). The slack export cannot be joined "
            "onto the network buses."
        )

    slack = slack_export[slack_export["outerloop_iteration"] == outerloop].copy()
    if slack.empty:
        raise ValueError(
            f"No slack exported for outer loop iteration {outerloop}. "
            f"Available iterations: {sorted(slack_export['outerloop_iteration'].unique())}."
        )

    # The solver may export decimal commas depending on the JVM locale.
    slack["slackValue_pu"] = pd.to_numeric(
        slack["slackValue_pu"].astype(str).str.replace(",", ".", regex=False),
        errors="coerce",
    )

    # 'voltage_level_id' exists on both sides; keep the one from the network.
    slack = slack.drop(columns=["voltage_level_id"], errors="ignore")

    unmatched = set(slack["bus_id"]) - set(buses["bus_id"])
    if unmatched:
        print(f"Warning: {len(unmatched)} exported bus id(s) absent from the network: {sorted(unmatched)}")

    slack_info = (
        buses.join(slack.set_index("bus_id"), on="bus_id", how="left")
        .drop_duplicates()
        .reset_index()  # the bus-breaker bus id becomes the 'id' column
    )
    slack_info["has_slack"] = slack_info["slackValue_pu"].notna()
    return slack_info


def _slack_emojis(buses: DataFrame) -> str:
    """Return the concatenated emojis of the slack types present in ``buses``."""
    types = set(buses.loc[buses["has_slack"], "type"].dropna()) & set(SLACK_EMOJI)
    return "".join(SLACK_EMOJI[t] for t in sorted(types)) if types else NO_SLACK_EMOJI


def _describe_slack(row: pd.Series) -> str:
    """Describe the network elements that explain a slack on this bus."""
    fields = {
        "P": [("generator", "generator"), ("load", "load")],
        "Q": [("shunt", "shunt")],
        "V": [("generator", "generator"), ("controleVoltage", "voltage control")],
    }.get(row.get("type"), [])

    present = [
        f"{label}: {row[column]}"
        for column, label in fields
        if pd.notna(row.get(column))
    ]
    return ", ".join(present) if present else "no related element found"


def _format_bus_row(row: pd.Series) -> str:
    """Render one bus as an HTML line of the slack detail panel."""
    bus_id = row.get("id", "")
    merged_bus = row.get("bus_id", "")
    if not row.get("has_slack", False):
        return f"{NO_SLACK_EMOJI} <b>{bus_id}</b> (bus {merged_bus}): no slack"

    slack_type = row.get("type")
    emoji = SLACK_EMOJI.get(slack_type, NO_SLACK_EMOJI)
    value = row.get("slackValue_pu")
    value_str = f"{value:.4f}" if pd.notna(value) else "N/A"
    return (
        f"{emoji} <b>{bus_id}</b> (bus {merged_bus}): "
        f"slack of {slack_type} = {value_str} p.u. &mdash; {_describe_slack(row)}"
    )


def nad_explorer_with_slack(
    network: Network,
    slack_info: DataFrame,
    voltage_level_ids: list = None,
    depth: int = 1,
    low_nominal_voltage_bound: float = -1,
    high_nominal_voltage_bound: float = -1,
    parameters: NadParameters = None,
    fixed_nad_positions: DataFrame = None,
    nad_profile: "NadProfile" = None,
):
    """Network area diagram explorer augmented with Knitro slack information.

    Args:
        network: the network to display.
        slack_info: the dataframe returned by :func:`compute_slack_info`.
        voltage_level_ids: voltage levels to display initially; ``None`` for all.
        depth: diagram depth around the selected voltage levels.
        low_nominal_voltage_bound: low bound to filter VLs by nominal voltage.
        high_nominal_voltage_bound: high bound to filter VLs by nominal voltage.
        parameters: NAD layout parameters.
        fixed_nad_positions: fixed voltage level positions for the layout.
        nad_profile: optional NAD styling profile.

    Returns:
        An ``ipywidgets`` box to be displayed as the last expression of a cell.
    """
    vls = network.get_voltage_levels(attributes=[])
    nad_widget = None

    selected_vl = list(vls.index) if voltage_level_ids is None else voltage_level_ids
    if len(selected_vl) == 0:
        raise ValueError("At least one VL must be selected in the voltage_level_ids list")

    selected_depth = depth

    npars = parameters if parameters is not None else NadParameters(
        edge_name_displayed=False,
        id_displayed=False,
        edge_info_along_edge=True,
        power_value_precision=1,
        angle_value_precision=0,
        current_value_precision=1,
        voltage_value_precision=0,
        bus_legend=True,
        substation_description_displayed=True,
    )

    def update_diagram():
        nonlocal nad_widget
        if not selected_vl:
            return
        diagram = network.get_network_area_diagram(
            voltage_level_ids=selected_vl,
            depth=selected_depth,
            high_nominal_voltage_bound=high_nominal_voltage_bound,
            low_nominal_voltage_bound=low_nominal_voltage_bound,
            nad_parameters=npars,
            fixed_positions=fixed_nad_positions,
            nad_profile=nad_profile,
        )
        if nad_widget is None:
            nad_widget = display_nad(diagram, drag_enabled=True)
        else:
            update_nad(nad_widget, diagram, drag_enabled=True)

    def vl_label(vl_id: str) -> str:
        return f"{vl_id} {_slack_emojis(slack_info[slack_info['voltage_level_id'] == vl_id])}"

    # --- widgets -------------------------------------------------------------

    depth_slider = widgets.IntSlider(
        value=selected_depth, min=0, max=20, step=1, description="depth:",
        continuous_update=False, readout_format="d",
    )

    slack_filter = widgets.Dropdown(
        options=["All VLs", "VLs with slack", "Type: P (active)",
                 "Type: Q (reactive)", "Type: V (voltage)"],
        value="All VLs",
        description="Slack info:",
    )

    vl_input = widgets.Text(
        value="", placeholder="Voltage level ID", description="Filter",
        continuous_update=True,
    )

    found = widgets.SelectMultiple(
        options=[(vl_label(vl), vl) for vl in vls.index],
        value=selected_vl,
        description="Found",
        layout=widgets.Layout(height="350px"),
    )

    slack_legend = widgets.HTML(
        value=(
            "<b>Slack type legend:</b><br>"
            f"{SLACK_EMOJI['P']}&nbsp;Active power (P)<br>"
            f"{SLACK_EMOJI['Q']}&nbsp;Reactive power (Q)<br>"
            f"{SLACK_EMOJI['V']}&nbsp;Voltage (V)<br>"
            f"{NO_SLACK_EMOJI}&nbsp;No slack<br>"
        )
    )

    slack_label = widgets.HTML(
        value="<b>Slack information:</b><br><i>Select voltage levels to see details</i>",
        layout=widgets.Layout(max_width="800px"),
    )

    # --- callbacks -----------------------------------------------------------

    def on_depth_changed(change):
        nonlocal selected_depth
        selected_depth = change["new"]
        update_diagram()

    def on_text_changed(change):
        nonlocal selected_vl
        matching = vls[vls.index.str.contains(change["new"], regex=False)].index
        found.options = [(vl_label(vl), vl) for vl in matching]
        selected_vl = []

    def on_filter_changed(change):
        nonlocal selected_vl
        by_vl = slack_info[slack_info["has_slack"]].groupby("voltage_level_id")

        def has_type(vl, slack_type=None):
            if vl not in by_vl.groups:
                return False
            group = by_vl.get_group(vl)
            return group["type"].notna().any() if slack_type is None else group["type"].eq(slack_type).any()

        criteria = {
            "VLs with slack": lambda vl: has_type(vl),
            "Type: P (active)": lambda vl: has_type(vl, "P"),
            "Type: Q (reactive)": lambda vl: has_type(vl, "Q"),
            "Type: V (voltage)": lambda vl: has_type(vl, "V"),
        }.get(change["new"], lambda vl: True)

        found.options = [(vl_label(vl), vl) for vl in vls.index if criteria(vl)]
        selected_vl = []

    def on_selected(change):
        nonlocal selected_vl
        if change["new"] is None:
            return
        selected_vl = change["new"]

        sections = []
        for vl in selected_vl:
            buses = slack_info[slack_info["voltage_level_id"] == vl]
            if buses.empty:
                sections.append(f"<b>Voltage level {vl}:</b> no bus information")
            else:
                lines = [_format_bus_row(row) for _, row in buses.iterrows()]
                sections.append(f"<b>Voltage level {vl} buses:</b><br>" + "<br>".join(lines))
        slack_label.value = "<br><br>".join(sections)

        update_diagram()

    depth_slider.observe(on_depth_changed, names="value")
    vl_input.observe(on_text_changed, names="value")
    slack_filter.observe(on_filter_changed, names="value")
    found.observe(on_selected, names="value")

    update_diagram()

    # --- layout --------------------------------------------------------------

    left_panel = widgets.VBox([
        widgets.Label("Knitro RELAXED solver"),
        slack_legend,
        slack_filter,
        vl_input,
        widgets.Label("Results:"),
        found,
        widgets.HTML('<hr style="margin: 10px 0;">'),
        slack_label,
    ])
    right_panel = widgets.VBox([depth_slider, nad_widget])

    layout = widgets.HBox([left_panel, right_panel])
    layout.layout.align_items = "flex-start"
    return layout
