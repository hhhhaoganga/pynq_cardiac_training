`timescale 1ns/1ps

// Exact 8-connected largest-component filter for the three foreground classes.
// Pixel labels are stored outside this core between passes; only row state and
// bounded union/find tables live in PL. Label words use {2'b0,class[1:0],id[11:0]}.
module camus_lcc_core #(
    parameter integer MAX_WIDTH = 256,
    parameter integer MAX_LABELS = 512,
    parameter integer LABEL_W = $clog2(MAX_LABELS)
) (
    input  logic clk,
    input  logic rst,
    input  logic start,
    input  logic [8:0] width,
    input  logic [8:0] height,

    input  logic s_mask_valid,
    output logic s_mask_ready,
    input  logic [7:0] s_mask_class,
    output logic m_label_valid,
    input  logic m_label_ready,
    output logic [15:0] m_label,

    output logic area_phase,
    input  logic s_area_valid,
    output logic s_area_ready,
    input  logic [15:0] s_area_label,

    output logic filter_phase,
    input  logic s_filter_valid,
    output logic s_filter_ready,
    input  logic [15:0] s_filter_label,
    output logic m_mask_valid,
    input  logic m_mask_ready,
    output logic [7:0] m_mask_class,

    output logic busy,
    output logic done,
    output logic error,
    output logic overflow,
    output logic [LABEL_W:0] labels_used,
    output logic [63:0] cycle_count
);
    typedef enum logic [4:0] {
        S_IDLE, S_INIT, S_LABEL, S_SELECT_MIN, S_SELECT_PREP, S_SELECT_UNION_PREP,
        S_SELECT, S_UNION_PREP,
        S_UNION_WRITE, S_LABEL_DRAIN,
        S_FLAT_BEGIN, S_FLAT_WALK, S_AREA, S_AREA_UPDATE, S_FILTER,
        S_FILTER_DRAIN, S_DONE
    } state_t;
    state_t state;

    localparam integer AREA_W = 17;
    localparam logic [LABEL_W-1:0] LAST_LABEL = MAX_LABELS-1;

    (* ram_style = "distributed" *) logic [LABEL_W-1:0] parent [0:MAX_LABELS-1];
    (* ram_style = "distributed" *) logic [LABEL_W-1:0] root_map [0:MAX_LABELS-1];
    (* ram_style = "distributed" *) logic [AREA_W-1:0] root_area [0:MAX_LABELS-1];
    (* ram_style = "distributed" *) logic [LABEL_W+1:0] row0 [0:MAX_WIDTH-1];
    (* ram_style = "distributed" *) logic [LABEL_W+1:0] row1 [0:MAX_WIDTH-1];

    logic [8:0] width_reg,height_reg,x,y;
    logic current_bank;
    logic [LABEL_W+1:0] west_word;
    logic [LABEL_W:0] next_label;
    logic [LABEL_W-1:0] union_labels [0:3];
    logic [LABEL_W-1:0] union_target;
    logic [LABEL_W-1:0] selected_label_reg;
    logic [LABEL_W-1:0] prepared_assigned_label,prepared_union_target;
    logic prepared_new_component,prepared_has_union;
    logic [2:0] union_index;
    logic [LABEL_W-1:0] union_label_reg,union_parent_reg;
    logic last_label_pixel;
    logic [1:0] pixel_class;
    logic [LABEL_W-1:0] init_index,flatten_label,walk_label;
    logic [LABEL_W:0] flatten_limit;
    logic [LABEL_W:0] walk_depth;
    logic [31:0] area_pixels,filter_pixels,total_pixels;
    logic [AREA_W-1:0] max_area [1:3];
    logic [LABEL_W-1:0] max_root [1:3];
    logic [1:0] area_class_pending;
    logic [LABEL_W-1:0] area_root_pending;
    logic last_area_pixel;

    logic [LABEL_W+1:0] nw_word,n_word,ne_word;
    logic [LABEL_W-1:0] neighbor_label [0:3];
    logic [LABEL_W-1:0] pair_min_01,pair_min_23,selected_label,assigned_label;
    // Registered pair minima: splits the 4-way min + compare chain that failed
    // 100 MHz timing (union_labels -> prepared_assigned_label) over two cycles.
    logic [LABEL_W-1:0] pair_min_01_reg,pair_min_23_reg;
    logic [1:0] input_class;
    logic selected_new_component,selected_has_union,selected_has_union_split;
    logic label_slot_available,mask_slot_available;
    logic label_fire,area_fire,filter_fire;
    logic [LABEL_W-1:0] area_label,area_root,filter_label,filter_root;
    logic [1:0] area_class,filter_class;
    logic [AREA_W-1:0] next_area;
    integer comb_index;
    integer seq_index;

    assign busy = state != S_IDLE;
    assign area_phase = state == S_AREA || state == S_AREA_UPDATE;
    assign filter_phase = state == S_FILTER || state == S_FILTER_DRAIN;
    assign label_slot_available = !m_label_valid || m_label_ready;
    assign mask_slot_available = !m_mask_valid || m_mask_ready;
    assign s_mask_ready = state == S_LABEL && label_slot_available;
    assign s_area_ready = state == S_AREA;
    assign s_filter_ready = state == S_FILTER && mask_slot_available;
    assign label_fire = s_mask_valid && s_mask_ready;
    assign area_fire = s_area_valid && s_area_ready;
    assign filter_fire = s_filter_valid && s_filter_ready;
    assign total_pixels = width_reg * height_reg;
    assign input_class = s_mask_class[1:0];

    always_comb begin
        if (y == 0) begin
            nw_word = '0;
            n_word = '0;
            ne_word = '0;
        end else if (current_bank) begin
            nw_word = x == 0 ? '0 : row0[x-1'b1];
            n_word = row0[x];
            ne_word = x+1'b1 >= width_reg ? '0 : row0[x+1'b1];
        end else begin
            nw_word = x == 0 ? '0 : row1[x-1'b1];
            n_word = row1[x];
            ne_word = x+1'b1 >= width_reg ? '0 : row1[x+1'b1];
        end

        neighbor_label[0] = west_word[LABEL_W+1:LABEL_W] == input_class
            ? west_word[LABEL_W-1:0] : '0;
        neighbor_label[1] = nw_word[LABEL_W+1:LABEL_W] == input_class
            ? nw_word[LABEL_W-1:0] : '0;
        neighbor_label[2] = n_word[LABEL_W+1:LABEL_W] == input_class
            ? n_word[LABEL_W-1:0] : '0;
        neighbor_label[3] = ne_word[LABEL_W+1:LABEL_W] == input_class
            ? ne_word[LABEL_W-1:0] : '0;
        pair_min_01 = union_labels[0] == 0 ? union_labels[1]
            : union_labels[1] == 0 ? union_labels[0]
            : union_labels[0] < union_labels[1] ? union_labels[0] : union_labels[1];
        pair_min_23 = union_labels[2] == 0 ? union_labels[3]
            : union_labels[3] == 0 ? union_labels[2]
            : union_labels[2] < union_labels[3] ? union_labels[2] : union_labels[3];
        selected_label = pair_min_01_reg == 0 ? pair_min_23_reg
            : pair_min_23_reg == 0 ? pair_min_01_reg
            : pair_min_01_reg < pair_min_23_reg ? pair_min_01_reg : pair_min_23_reg;
        selected_new_component = pixel_class != 0 && selected_label == 0;
        assigned_label = pixel_class == 0 ? '0
            : selected_new_component ? next_label[LABEL_W-1:0] : selected_label;
        selected_has_union = 1'b0;
        for (comb_index=0;comb_index<4;comb_index=comb_index+1)
            if (union_labels[comb_index] != 0
                    && union_labels[comb_index] != selected_label)
                selected_has_union = 1'b1;
        selected_has_union_split = 1'b0;
        for (comb_index=0;comb_index<4;comb_index=comb_index+1)
            if (union_labels[comb_index] != 0
                    && union_labels[comb_index] != selected_label_reg)
                selected_has_union_split = 1'b1;

        area_class = s_area_label[LABEL_W+1:LABEL_W];
        area_label = s_area_label[LABEL_W-1:0];
        area_root = root_map[area_label];
        next_area = root_area[area_root_pending] + 1'b1;
        filter_class = s_filter_label[LABEL_W+1:LABEL_W];
        filter_label = s_filter_label[LABEL_W-1:0];
        filter_root = root_map[filter_label];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            width_reg <= 0; height_reg <= 0; x <= 0; y <= 0;
            current_bank <= 0; west_word <= 0; next_label <= 1;
            union_index <= 0; union_target <= 0; selected_label_reg <= 0;
            union_label_reg <= 0; union_parent_reg <= 0; last_label_pixel <= 0;
            prepared_assigned_label <= 0; prepared_union_target <= 0;
            prepared_new_component <= 0; prepared_has_union <= 0;
            pair_min_01_reg <= 0; pair_min_23_reg <= 0;
            pixel_class <= 0;
            init_index <= 0; flatten_label <= 0; walk_label <= 0;
            flatten_limit <= 0; walk_depth <= 0;
            area_pixels <= 0; filter_pixels <= 0;
            area_class_pending <= 0; area_root_pending <= 0; last_area_pixel <= 0;
            m_label_valid <= 0; m_label <= 0;
            m_mask_valid <= 0; m_mask_class <= 0;
            done <= 0; error <= 0; overflow <= 0;
            labels_used <= 0; cycle_count <= 0;
            for (seq_index=1;seq_index<=3;seq_index=seq_index+1) begin
                max_area[seq_index] <= 0;
                max_root[seq_index] <= 0;
            end
        end else begin
            done <= 0;
            if (busy)
                cycle_count <= cycle_count + 1'b1;
            if (m_label_valid && m_label_ready)
                m_label_valid <= 0;
            if (m_mask_valid && m_mask_ready && !filter_fire)
                m_mask_valid <= 0;
            if (start && busy)
                error <= 1'b1;

            case (state)
                S_IDLE: if (start) begin
                    if (width == 0 || height == 0 || width > MAX_WIDTH) begin
                        error <= 1'b1;
                        done <= 1'b1;
                    end else begin
                        width_reg <= width; height_reg <= height;
                        x <= 0; y <= 0; current_bank <= 0; west_word <= 0;
                        next_label <= 1; init_index <= 0;
                        area_pixels <= 0; filter_pixels <= 0;
                        m_label_valid <= 0; m_mask_valid <= 0;
                        error <= 0; overflow <= 0; labels_used <= 0;
                        cycle_count <= 0;
                        for (seq_index=1;seq_index<=3;seq_index=seq_index+1) begin
                            max_area[seq_index] <= 0;
                            max_root[seq_index] <= 0;
                        end
                        state <= S_INIT;
                    end
                end

                S_INIT: begin
                    parent[init_index] <= init_index;
                    root_map[init_index] <= 0;
                    root_area[init_index] <= 0;
                    if (init_index == LAST_LABEL) begin
                        init_index <= 0;
                        state <= S_LABEL;
                    end else init_index <= init_index + 1'b1;
                end

                S_LABEL: if (label_fire) begin
                    pixel_class <= input_class;
                    last_label_pixel <= x == width_reg-1'b1 && y == height_reg-1'b1;
                    for (seq_index=0;seq_index<4;seq_index=seq_index+1)
                        union_labels[seq_index] <= neighbor_label[seq_index];
                    state <= S_SELECT_MIN;
                end

                S_SELECT_MIN: begin
                    pair_min_01_reg <= pair_min_01;
                    pair_min_23_reg <= pair_min_23;
                    state <= S_SELECT_PREP;
                end

                S_SELECT_PREP: begin
                    prepared_assigned_label <= assigned_label;
                    prepared_union_target <= selected_label;
                    prepared_new_component <= selected_new_component;
                    selected_label_reg <= selected_label;
                    state <= S_SELECT_UNION_PREP;
                end

                S_SELECT_UNION_PREP: begin
                    prepared_has_union <= selected_has_union_split;
                    state <= S_SELECT;
                end

                S_SELECT: begin
                    m_label <= {{(14-LABEL_W){1'b0}},pixel_class,prepared_assigned_label};
                    m_label_valid <= 1'b1;
                    union_target <= prepared_union_target;
                    union_index <= 0;

                    if (prepared_new_component) begin
                        if (next_label[LABEL_W] || next_label[LABEL_W-1:0] == LAST_LABEL) begin
                            overflow <= 1'b1;
                            error <= 1'b1;
                        end else begin
                            parent[next_label[LABEL_W-1:0]] <= next_label[LABEL_W-1:0];
                            next_label <= next_label + 1'b1;
                        end
                    end
                    if (current_bank)
                        row1[x] <= {pixel_class,prepared_assigned_label};
                    else
                        row0[x] <= {pixel_class,prepared_assigned_label};
                    west_word <= {pixel_class,prepared_assigned_label};
                    if (x == width_reg-1'b1) begin
                        x <= 0;
                        y <= y + 1'b1;
                        current_bank <= ~current_bank;
                        west_word <= 0;
                    end else x <= x + 1'b1;

                    if (prepared_has_union)
                        state <= S_UNION_PREP;
                    else if (x == width_reg-1'b1 && y == height_reg-1'b1)
                        state <= S_LABEL_DRAIN;
                    else
                        state <= S_LABEL;
                end

                S_UNION_PREP: begin
                    union_label_reg <= union_labels[union_index];
                    union_parent_reg <= parent[union_labels[union_index]];
                    state <= S_UNION_WRITE;
                end

                S_UNION_WRITE: begin
                    if (union_label_reg != 0 && union_label_reg != union_target
                            && union_parent_reg > union_target)
                        parent[union_label_reg] <= union_target;
                    if (union_index == 3) begin
                        if (last_label_pixel)
                            state <= S_LABEL_DRAIN;
                        else
                            state <= S_LABEL;
                    end else begin
                        union_index <= union_index + 1'b1;
                        state <= S_UNION_PREP;
                    end
                end

                S_LABEL_DRAIN: if (!m_label_valid || m_label_ready) begin
                    labels_used <= next_label - 1'b1;
                    flatten_limit <= next_label;
                    flatten_label <= 1;
                    state <= S_FLAT_BEGIN;
                end

                S_FLAT_BEGIN: begin
                    if (flatten_label >= flatten_limit) begin
                        area_pixels <= 0;
                        state <= S_AREA;
                    end else begin
                        walk_label <= flatten_label;
                        walk_depth <= 0;
                        state <= S_FLAT_WALK;
                    end
                end

                S_FLAT_WALK: begin
                    if (parent[walk_label] == walk_label) begin
                        root_map[flatten_label] <= walk_label;
                        flatten_label <= flatten_label + 1'b1;
                        state <= S_FLAT_BEGIN;
                    end else if (walk_depth >= MAX_LABELS-1) begin
                        error <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        walk_label <= parent[walk_label];
                        walk_depth <= walk_depth + 1'b1;
                    end
                end

                S_AREA: if (area_fire) begin
                    area_class_pending <= area_class;
                    area_root_pending <= area_root;
                    last_area_pixel <= area_pixels == total_pixels-1'b1;
                    if (area_pixels != total_pixels-1'b1)
                        area_pixels <= area_pixels + 1'b1;
                    state <= S_AREA_UPDATE;
                end

                S_AREA_UPDATE: begin
                    if (area_class_pending != 0 && area_root_pending != 0) begin
                        root_area[area_root_pending] <= next_area;
                        if (next_area > max_area[area_class_pending]) begin
                            max_area[area_class_pending] <= next_area;
                            max_root[area_class_pending] <= area_root_pending;
                        end
                    end
                    if (last_area_pixel) begin
                        filter_pixels <= 0;
                        state <= S_FILTER;
                    end else state <= S_AREA;
                end

                S_FILTER: if (filter_fire) begin
                    m_mask_class <= filter_class != 0 && filter_label != 0
                            && filter_root == max_root[filter_class]
                        ? {6'd0,filter_class} : 8'd0;
                    m_mask_valid <= 1'b1;
                    if (filter_pixels == total_pixels-1'b1)
                        state <= S_FILTER_DRAIN;
                    else filter_pixels <= filter_pixels + 1'b1;
                end

                S_FILTER_DRAIN: if (!m_mask_valid || m_mask_ready)
                    state <= S_DONE;

                S_DONE: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
