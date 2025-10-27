-- rx_fifo_axis_flush_cfg.vhd
-- AXIS RX FIFO with idle-timeout flush (runtime configurable)
--   - Normal frame when FIFO has >= i_frame_bytes
--   - Otherwise, if idle for i_idle_flush_bytes UART-byte times, flush partial
-- Notes:
--   * Only FIFO_DEPTH is generic (memory size).
--   * i_clks_per_bit is the UART bit-time in fabric clocks (e.g., 100MHz/115200 ≈ 868).
--   * CLKS_PER_BYTE = 10 * i_clks_per_bit (start + 8 data + stop) via shift-add.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_fifo_axis_flush_cfg is
    generic (
        FIFO_DEPTH : integer := 128  -- power-of-2 recommended
    );
    port (
        CLK                : in  std_logic;
        RSTn               : in  std_logic;  -- active-low

        -- UART RX byte interface
        i_rx_dv            : in  std_logic;                        -- 1-cycle pulse per received byte
        i_rx_byte          : in  std_logic_vector(7 downto 0);

        -- AXI4-Stream Master (to AXI DMA S2MM)
        M_AXIS_TVALID      : out std_logic;
        M_AXIS_TREADY      : in  std_logic;
        M_AXIS_TDATA       : out std_logic_vector(7 downto 0);
        M_AXIS_TKEEP       : out std_logic_vector(0 downto 0);
        M_AXIS_TLAST       : out std_logic;

        -- Status / debug
        fifo_count         : out unsigned(15 downto 0);
        overflow           : out std_logic;                        -- sticky overflow (RX byte dropped)
        frame_count        : out unsigned(31 downto 0);
        	
        o_fifo_empty		: out std_logic; 	
        o_fifo_full         : out std_logic;
        -- Runtime configuration
        i_frame_bytes      : in  std_logic_vector(15 downto 0);    -- bytes per normal TLAST frame
        i_idle_flush_bytes : in  std_logic_vector(7 downto 0);     -- UART byte-times before flushing partial
        i_clks_per_bit     : in  std_logic_vector(15 downto 0)     -- fabric clocks per UART bit
    );
end entity;

architecture rtl of rx_fifo_axis_flush_cfg is
    -- Storage
    type mem_t is array (0 to FIFO_DEPTH-1) of std_logic_vector(7 downto 0);
    signal mem : mem_t;

    -- Pointers and occupancy
    signal wr_ptr  			: integer range 0 to FIFO_DEPTH-1 := 0;
    signal rd_ptr  			: integer range 0 to FIFO_DEPTH-1 := 0;
    signal occ     			: integer range 0 to FIFO_DEPTH   := 0;
                        	
    -- Output registers 	
    signal m_data_r   		: std_logic_vector(7 downto 0) := (others => '0');
    signal m_valid_r  		: std_logic := '0';
    signal m_last_r   		: std_logic := '0';

    -- Stream control
    signal stream_active 	: std_logic := '0';
    signal bytes_left    	: integer range 0 to 65535 := 0;  -- frame bytes remaining

    -- Handshakes / events
    signal pop        		: std_logic;   -- AXIS handshake (out)
    signal push       		: std_logic;   -- UART byte accepted (in)

    -- Sticky overflow
    signal overflow_r 		: std_logic := '0';   
    signal r_fifo_full		: std_logic := '0';
    signal r_fifo_empty		: std_logic := '0';

    -- Counters
    signal frame_cnt_r 		: unsigned(31 downto 0) := (others => '0');

    -- ===== Runtime timeout calculation =====
    -- CLKS_PER_BYTE = 10 * i_clks_per_bit = (<<3) + (<<1)
    signal clks_per_bit_u     : unsigned(15 downto 0);
    signal clks_per_byte_u    : unsigned(19 downto 0);  -- up to ~655350
    signal idle_flush_bytes_u : unsigned(7 downto 0);
    signal idle_timeout_u     : unsigned(27 downto 0);  -- 20b * 8b -> 28b
    signal idle_cnt_u         : unsigned(27 downto 0) := (others => '0');

    -- Helpers
    function inc_wrap(i : integer; depth : integer) return integer is
    begin
        if i = depth-1 then
            return 0;
        else
            return i + 1;
        end if;
    end function;

begin
    --------------------------------------------------------------------
    -- Outputs
    --------------------------------------------------------------------
    M_AXIS_TDATA  <= m_data_r;
    M_AXIS_TVALID <= m_valid_r;
    M_AXIS_TKEEP  <= "1";
    M_AXIS_TLAST  <= m_last_r;
    o_fifo_empty  <= r_fifo_empty;	
    o_fifo_full   <= r_fifo_full;

    -- TLAST asserted on final beat of current frame
    m_last_r <= '1' when (stream_active = '1' and m_valid_r = '1' and bytes_left = 1) else '0';
    	
    -- FIFO status signals 
    -- NEW: simple empty/full flags (concurrent)
    r_fifo_empty <= '1' when occ = 0          else '0';
    r_fifo_full  <= '1' when occ = FIFO_DEPTH else '0';	

    fifo_count  <= to_unsigned(occ, fifo_count'length);
    overflow    <= overflow_r;
    frame_count <= frame_cnt_r;

    pop <= M_AXIS_TREADY and m_valid_r;

    -- ===== Runtime math for idle timeout (fixed width) =====
    clks_per_bit_u     <= unsigned(i_clks_per_bit);
    idle_flush_bytes_u <= unsigned(i_idle_flush_bytes);

    -- 10x using shift-add (no multiplier): (x<<3) + (x<<1)
    clks_per_byte_u <= resize((clks_per_bit_u sll 3) + (clks_per_bit_u sll 1),
                              clks_per_byte_u'length);  -- 20 bits

    -- Multiply 20b * 8b -> 28b result directly (no pre-resize that would widen)
    idle_timeout_u <= clks_per_byte_u * idle_flush_bytes_u;

    --------------------------------------------------------------------
    -- Main process
    --------------------------------------------------------------------
    process (CLK)
        variable next_rd       : integer range 0 to FIFO_DEPTH-1;
        variable frame_bytes_v : integer range 0 to 65535;
    begin
        if rising_edge(CLK) then
            if RSTn = '0' then
                wr_ptr        <= 0;
                rd_ptr        <= 0;
                occ           <= 0;
                m_data_r      <= (others => '0');
                m_valid_r     <= '0';
                stream_active <= '0';
                bytes_left    <= 0;
                overflow_r    <= '0';
                frame_cnt_r   <= (others => '0');
                idle_cnt_u    <= (others => '0');

            else
                ----------------------------------------------------------
                -- UART push (accept if space, or if a pop occurs at full)
                ----------------------------------------------------------
                push <= '0';  -- default

                -- Frame size as integer (cap later against FIFO_DEPTH)
                frame_bytes_v := to_integer(unsigned(i_frame_bytes));

                if i_rx_dv = '1' then
                    -- reset idle timer on any received byte
                    idle_cnt_u <= (others => '0');

                    if (occ < FIFO_DEPTH) or ((occ = FIFO_DEPTH) and (pop = '1')) then
                        mem(wr_ptr) <= i_rx_byte;
                        wr_ptr      <= inc_wrap(wr_ptr, FIFO_DEPTH);
                        if not (occ = FIFO_DEPTH and pop = '1') then
                            occ <= occ + 1;
                        end if;
                        push <= '1';
                    else
                        -- drop byte on overflow
                        overflow_r <= '1';
                    end if;

                else
                    -- No new byte: advance idle timer only when
                    -- not currently streaming and there is data buffered.
                    if (stream_active = '0') and (occ > 0) then
                        if idle_cnt_u < idle_timeout_u then
                            idle_cnt_u <= idle_cnt_u + 1;
                        end if;
                    else
                        idle_cnt_u <= (others => '0');  -- parked during streaming or when empty
                    end if;
                end if;

                ----------------------------------------------------------
                -- Start streaming when enough bytes OR on idle-timeout
                ----------------------------------------------------------
                if (stream_active = '0') then
                    -- Cap requested frame size to FIFO depth to avoid oversizing bytes_left
                    if frame_bytes_v > FIFO_DEPTH then
                        frame_bytes_v := FIFO_DEPTH;
                    elsif frame_bytes_v < 1 then
                        frame_bytes_v := 1;
                    end if;

                    if occ >= frame_bytes_v then
                        -- Normal full frame
                        stream_active <= '1';
                        bytes_left    <= frame_bytes_v;

                        if m_valid_r = '0' then
                            m_data_r  <= mem(rd_ptr);
                            m_valid_r <= '1';
                        end if;

                    elsif (occ > 0) and (idle_cnt_u >= idle_timeout_u) then
                        -- Idle-timeout: flush partial frame (occ < frame_bytes_v)
                        stream_active <= '1';
                        bytes_left    <= occ;  -- bounded by FIFO_DEPTH

                        if m_valid_r = '0' then
                            m_data_r  <= mem(rd_ptr);
                            m_valid_r <= '1';
                        end if;

                        idle_cnt_u <= (others => '0');  -- consume the timeout
                    end if;

                -- Streaming a frame
                elsif stream_active = '1' then
                    -- While streaming, keep idle timer reset
                    idle_cnt_u <= (others => '0');

                    if pop = '1' then
                        -- consume one byte from FIFO
                        rd_ptr     <= inc_wrap(rd_ptr, FIFO_DEPTH);
                        occ        <= occ - 1;
                        bytes_left <= bytes_left - 1;

                        -- Prepare next byte (if more in this frame)
                        if bytes_left > 1 then
                            next_rd  := inc_wrap(rd_ptr, FIFO_DEPTH);
                            m_data_r <= mem(next_rd);
                            -- m_valid_r stays '1'
                        else
                            -- last beat of this frame just handshaked (TLAST=1 this cycle)
                            stream_active <= '0';
                            m_valid_r     <= '0';
                            frame_cnt_r   <= frame_cnt_r + 1;
                            -- Optional: immediate back-to-back partial frame start can be enabled here
                        end if;
                    end if; -- pop
                end if; -- stream_active
            end if; -- reset
        end if; -- clk
    end process;
    
    -- ILA (unchanged)                                              
	-- probe8 shows m_last_r, now driven by bytes_left logic        
	Inst_ila_3 : entity work.ila_3                                  
  		port map (                                                    
  		  	clk      		=> CLK,                                            
  		  	probe0			=> std_logic_vector(to_unsigned(occ,8)),                                        
  		  	probe1(0)		=> r_fifo_empty,
  		  	probe2(0)		=> r_fifo_full ,                                       
  		  	probe3(0)		=> overflow_r                                  
   		);    
    

end architecture;
