"""
Enhanced NAD Explorer with Slack Information Visualization

Extends the original nad_explorer with slack bus visualization capabilities.
Includes filtering by slack type (P, Q, V) and visual indicators.
"""

import ipywidgets as widgets
import pandas as pd
import re
from html import escape
from pandas import DataFrame
from pypowsybl.network import Network, NadParameters
try:
    from pypowsybl.network import NadProfile
except ImportError:
    NadProfile = None
from pypowsybl_jupyter import nad_explorer as original_nad_explorer
from pypowsybl_jupyter.nadwidget import display_nad, update_nad
from ipywidgets import HTML

import pandas as pd
import math

def calculate_dc_losses(dc_network, voltage_level_df):
    total_losses = 0.0
    # Get a DataFrame with default attributes (or add more in the list if you want)
    lines_df = dc_network.get_lines()


    for line_id, row in lines_df.iterrows():
        r = row['r']
        p1 = row['p1']
        v_level_id = row['voltage_level1_id']

        if r == 0 or math.isnan(p1):
            continue

        vnom1 = voltage_level_df.loc[v_level_id,'nominal_v']  # Get the nominal voltage for this level

        loss = r * (abs(p1) ** 2) / (vnom1 ** 2)
        total_losses += loss

    return total_losses

def compute_slack_info(network, data):
    """
    Parameters
    ----------
    network : network loaded using pypowsybl.network (from an iidm file)
    data : pd.DataFrame, slack information exported 
        Data with a 'busId' column and slack information.
    Returns
    -------
    pd.DataFrame
        Merged DataFrame with 'has_slack' column.
    """
    # Join on bus ID
    slack_info = network.get_bus_breaker_view_buses().join(
        data.set_index("busId"),
        on="bus_id",
        how="left"
    ).drop_duplicates()
    slack_info["slackValue_pu"] = (
    slack_info["slackValue_pu"]
      .astype(str)
      .str.replace(",", ".", regex=False)
    )

    slack_info["slackValue_pu"] = pd.to_numeric(slack_info["slackValue_pu"], errors="coerce")
    
    slack_info.reset_index(inplace=True)
    slack_info["has_slack"] = slack_info["slackValue_pu"].notna()
    return slack_info

# def inject_bus_colors_into_svg(svg_string, bus_colors_dict):
#     """
#     Inject bus node colors directly into SVG by modifying circle elements.
    
#     Args:
#         svg_string: Raw SVG string
#         bus_colors_dict: Dict mapping bus_id (str) -> {'fill': color, 'edge': edge_color, 'edge-width': width}
    
#     Returns:
#         Modified SVG string with colors injected
#     """
#     modified_svg = svg_string
    
#     for bus_id, style_info in bus_colors_dict.items():
#         # Find circle elements with this bus ID
#         # Pattern: <circle ... id="bus_id" ... />
#         pattern = rf'(<circle[^>]*\bid=["\']?{re.escape(str(bus_id))}["\']?[^>]*?)(/?>)'
        
#         def replace_func(match):
#             circle_tag = match.group(1)
#             closing = match.group(2)
            
#             # Add fill color
#             fill_color = style_info.get('fill', '#ccc')
#             # Check if fill already exists
#             if 'fill=' in circle_tag:
#                 # Replace existing fill
#                 circle_tag = re.sub(r'fill=["\']?[^"\'\s/>]+["\']?', f'fill="{fill_color}"', circle_tag)
#             else:
#                 # Add new fill attribute
#                 circle_tag += f' fill="{fill_color}"'
            
#             # Add edge (stroke) color
#             edge_color = style_info.get('edge', '#333')
#             if 'stroke=' in circle_tag:
#                 circle_tag = re.sub(r'stroke=["\']?[^"\'\s/>]+["\']?', f'stroke="{edge_color}"', circle_tag)
#             else:
#                 circle_tag += f' stroke="{edge_color}"'
            
#             # Add stroke width
#             edge_width = style_info.get('edge-width', '2')
#             if 'stroke-width=' in circle_tag:
#                 circle_tag = re.sub(r'stroke-width=["\']?[^"\'\s/>]+["\']?', f'stroke-width="{edge_width}"', circle_tag)
#             else:
#                 circle_tag += f' stroke-width="{edge_width}"'
            
#             return circle_tag + closing
        
#         modified_svg = re.sub(pattern, replace_func, modified_svg)
    
#     return modified_svg


def nad_explorer_with_slack(network: Network, 
                            voltage_level_ids: list = None, 
                            depth: int = 1,
                            time_series_data: pd.DataFrame = None, 
                            low_nominal_voltage_bound: float = -1,
                            high_nominal_voltage_bound: float = -1, 
                            parameters: NadParameters = None,
                            fixed_nad_positions: DataFrame = None,
                            slack_info: pd.DataFrame = None,
                            nad_profile: NadProfile = None,
                            outerloop: int = 0):

                          
                          
    """
    Args:
        network: the input network
        voltage_level_ids: starting list of VL to display. None displays all VLs
        depth: diagram depth around the voltage level
        time_series_data: DataFrame with time series data
        low_nominal_voltage_bound: low bound to filter VL by nominal voltage
        high_nominal_voltage_bound: high bound to filter VL by nominal voltage
        parameters: NadParameters for layout properties
        fixed_nad_positions: positions dataframe for VL layout
        slack_info: DataFrame with slack information
        vl_descriptions: Optional DataFrame with VL descriptions
        bus_node_styles: Optional DataFrame with bus node styles
        edge_styles: Optional DataFrame with edge styles
        nad_profile: Optional NadProfile for original styling
    
    Returns:
        NAD explorer with slack info 
    """
    
    vls = network.get_voltage_levels(attributes=[])
    nad_widget = None
    # bus_ids = list(slack_info['bus_id'])
    slack_info["has_slack"] = slack_info["slackValue_pu"].notna()
    

    slack_info = slack_info[slack_info['outerloop_iteration'] == outerloop] 

    selected_vl = list(vls.index) if voltage_level_ids is None else voltage_level_ids
    if len(selected_vl) == 0:
        raise ValueError("At least one VL must be selected in the voltage_level_ids list")

    if time_series_data is not None:
        time_steps = sorted(time_series_data['timestamp'].unique())
        if len(time_steps) == 0:
            raise ValueError("time_series_data must contain at least one timestamp")
        selected_time_step = time_steps[0]

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
        substation_description_displayed=True
    )

    def prepare_branch_states(time_step):
        """
        Prepare branch states data for the selected time step.
        This function extracts the branch data for the given time step and formats it
        for the network-viewer API.
        """
        time_step_data = time_series_data[time_series_data['timestamp'] == time_step]

        branch_states = []
        for _, row in time_step_data.iterrows():
            if 'branch_id' not in row:
                print(f"Warning: 'branch_id' not found in row: {row}")
                continue

            branch_id = row['branch_id']
            branch_state = {
                'branchId': branch_id,
                'value1': float(row.get('value1', 0)),
                'value2': float(row.get('value2', 0)),
                'connected1': bool(row.get('connected1', True)),
                'connected2': bool(row.get('connected2', True)),
            }
            branch_states.append(branch_state)

        if not branch_states:
            print(f"Warning: No branch states found for time step {time_step}")

        return branch_states

    def update_diagram():
        nonlocal nad_widget
        if len(selected_vl) > 0:
            new_diagram_data = network.get_network_area_diagram(
                voltage_level_ids=selected_vl,
                depth=selected_depth,
                high_nominal_voltage_bound=high_nominal_voltage_bound,
                low_nominal_voltage_bound=low_nominal_voltage_bound,
                nad_parameters=npars,
                fixed_positions=fixed_nad_positions,
                nad_profile=nad_profile
            )
            if nad_widget == None:
                nad_widget = display_nad(new_diagram_data, drag_enabled=True)
            else:
                update_nad(nad_widget, new_diagram_data, drag_enabled=True)

            if time_series_data is not None:
                branch_states = prepare_branch_states(selected_time_step)
                if branch_states:
                    nad_widget.set_branch_states(branch_states)

    nadslider = widgets.IntSlider(
        value=selected_depth, min=0, max=20, step=1, description='depth:',
        disabled=False, continuous_update=False, orientation='horizontal',
        readout=True, readout_format='d'
    )

    def on_nadslider_changed(d):
        nonlocal selected_depth
        selected_depth = d['new']
        update_diagram()

    nadslider.observe(on_nadslider_changed, names='value')

    vl_input = widgets.Text(
        value='', placeholder='Voltage level ID', description='Filter',
        disabled=False, continuous_update=True
    )

    def on_text_changed(d):
        nonlocal selected_vl
        found.options = list(vls[vls.index.str.contains(d['new'], regex=False)].index)
        selected_vl = []

    vl_input.observe(on_text_changed, names='value')

    # Filter custom for slack vizualization
    slack_filter_options = ['All VLs','Slack VL']
    if slack_info is not None:
        slack_filter_options.extend(['Type: P (Active)', 'Type: Q (Reactive)', 'Type: V (Voltage)'])
    
    slack_filter = widgets.Dropdown(
        options=slack_filter_options,
        value='All VLs',
        description='Slack info:',
        disabled=False,
    )

    def apply_slack_filter(d):
        nonlocal selected_vl
        filter_value = d['new']
        
        if slack_info is None:
            found.options = list(vls.index)
            return
    
        slack_by_vl = slack_info.groupby("voltage_level_id")
        
        if filter_value == 'All VLs':
            filtered = list(vls.index)
        elif filter_value == 'Slack VL':
            filtered = [vl for vl in vls.index if vl in slack_by_vl.groups and slack_by_vl.get_group(vl)['type'].notna().any()]
        elif filter_value == 'Type: P (Active)':
            filtered = [vl for vl in vls.index if vl in slack_by_vl.groups and slack_by_vl.get_group(vl)['type'].eq('P').any()]
        elif filter_value == 'Type: Q (Reactive)':
            filtered = [vl for vl in vls.index if vl in slack_by_vl.groups and slack_by_vl.get_group(vl)['type'].eq('Q').any()]
        elif filter_value == 'Type: V (Voltage)':
            filtered = [vl for vl in vls.index if vl in slack_by_vl.groups and slack_by_vl.get_group(vl)['type'].eq('V').any()]
        else:
            filtered = list(vls.index)
        
        found.options = [(format_vl_label_with_slack(vl), vl) for vl in filtered]
        selected_vl = []

    slack_filter.observe(apply_slack_filter, names='value')

    
    # Format VL labels with slack in the slider
    
    def format_vl_label_with_slack(vl_id: str) -> str:
        """Format VL label with slack indicator (emoji symbols)."""
        buses = slack_info[slack_info['voltage_level_id'] == vl_id]

    # Emoji mapping
        slack_emoji_map = {
        'P': '🔴',
        'Q': '🔵',
        'V': '🟢',
        'none': '⚪',
        '': '⚪',
        }


        if not buses.empty:
            slack_types = set(buses.loc[buses['has_slack'] & buses['type'].notna(), 'type'])
            slack_types = {t for t in slack_types if t not in ('none', '')}
            if slack_types:
                emojis = ''.join(slack_emoji_map.get(t, '') for t in sorted(slack_types))
            else:
                emojis = '⚪'
        else:
            emojis = '⚪'

        return f"{vl_id} {emojis}"


    # Create dropdown with slack more detailed informations 
    if slack_info is not None:
        found_options = [(format_vl_label_with_slack(vl), vl) for vl in vls.index]
    else:
        found_options = [(vl, vl) for vl in vls.index]

    found = widgets.SelectMultiple(
        options=found_options,
        value=selected_vl,
        description='Found',
        disabled=False,
        layout=widgets.Layout(height='350px')
    )

    # DETAILED INFORMATIONS FOR EACH BUS
    
    def format_bus_slack_row(row):
    # Emoji based on slack type
        EMOJI_MAP = {'P': '🔴', 'Q': '🔵', 'V': '🟢', 'none': '⚪'}
        slack_type = row.get('type', 'none') or 'none'
        has_slack = row.get('has_slack', False)
        voltage_level_id = row.get('bus_id', '')
        bus_id = row.get('id','')
        try:
            val = float(row.get('slackValue_pu', 0))
            val_str = f"{val:.4f}"
        except Exception:
            val_str = "N/A"
        emoji = EMOJI_MAP.get(slack_type, EMOJI_MAP['none'])
        info = get_component(row)
        if has_slack:
            return f"{emoji} <b>{str(bus_id)} at {str(voltage_level_id)}</b>: Slack of {slack_type} = {val_str} p.u \n {info}"
        else:
            return f"{emoji} <b>{str(bus_id)} at {str(voltage_level_id)}</b>: No Slack"
        
    def get_component(row):
        x = row.get('type')
        mapping = {
            'P': active_slack, 
            'Q' : reactive_slack, 
            'V': voltage_slack}
    
        func = mapping.get(x, lambda _row:"none")
        return func(row) 
    
    def voltage_slack(row):
        info =[]
        if pd.notna(row.get('generator')): 
            info.append(f" Generator present: {row['generator']} ")
        if pd.notna(row.get('controleVoltage')):
            info.append(f"Control voltage: {row['controleVoltage']}")
        return ' '.join(info) if info else "No generator or control voltage"

        
    def active_slack(row):
        info = []
        if pd.notna(row.get('generator')): 
            info.append( f" Generator present: {row['generator']}")
        if pd.notna(row.get('load')):
            info.append( f" Load present: {row['load']}")
        return ' '.join(info) if info else f"No load or generator"
    
    def reactive_slack(row):
        if pd.notna(row['shunt']):
            return f" Shunt present: {row['shunt']}"
        return f"No shunt present"
    
    def on_selected(d):
        nonlocal selected_vl
        if d['new'] is not None:
            selected_vl = d['new']
            slack_display_items = []
            for vl in selected_vl:
                buses = slack_info[slack_info['voltage_level_id'] == vl]
                if not buses.empty:
                    lines = [format_bus_slack_row(row) for _, row in buses.iterrows()]
                    slack_display_items.append(f"<b>Voltage Level {vl} buses:</b><br>" + "<br>".join(lines))
                else:
                    slack_display_items.append(f"<b>Voltage Level {vl}:</b> No bus info")
            slack_label.value = '<br><br>'.join(slack_display_items)
        
        update_diagram()

    if time_series_data is not None :
        time_slider = widgets.SelectionSlider(
        options=[(str(ts), ts) for ts in time_steps],
        value=selected_time_step,
        description='time:',
        disabled=False,
        continuous_update=True,
        orientation='horizontal',
        readout=True,
        layout=widgets.Layout(width='50%')
    )
        
        def on_time_slider_changed(d):
            nonlocal selected_time_step
            selected_time_step = d['new']
            branch_states = prepare_branch_states(selected_time_step)
            if branch_states:
                nad_widget.set_branch_states(branch_states)

        time_slider.observe(on_time_slider_changed, names='value')

    found.observe(on_selected, names='value')
    update_diagram()

    # LEGEND 
    slack_label = widgets.HTML(
        value='<b>Slack Information:</b><br><i>Select voltage levels to see details</i>', 
        layout=widgets.Layout(max_width='800px')
    )
    
    slack_legend = widgets.HTML(
    value="""
    <b>Slack Type Legend:</b><br>
      <span>🔴&nbsp;Active Power (P)</sapn><br>
      <span>🔵&nbsp;Reactive Power (Q)</span><br>
      <span>🟢&nbsp;Voltage (V)</span><br>
      <span>⚪&nbsp;No Slack</sapn><br>
    """
    )
    left_panel = widgets.VBox([
        widgets.Label('Knitro RELAXED Solver'),
        slack_legend,
        slack_filter,
        vl_input,
        widgets.Label('Results:'),
        found,
        widgets.HTML('<hr style="margin: 10px 0;">'),
        slack_label
    ])

    if time_series_data is not None:
        right_panel = widgets.VBox([nadslider, time_slider, nad_widget])
    else:
        right_panel = widgets.VBox([nadslider, nad_widget])

    hbox = widgets.HBox([left_panel, right_panel])
    hbox.layout.align_items = 'flex-start'

    return hbox
