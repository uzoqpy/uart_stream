-- axi_top.vhd
-- Minimal AXI4-Lite slave with 5 independent channel processes.
-- No WSTRB handling: full 32-bit writes only.
-- Registers: REG0 @0x00 (RW), REG1 @0x04 (RW).
-- PDHS-facing ports exposed (not used inside yet).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity axi_top is
    generic (
       C_S_AXI_ADDR_WIDTH 		: integer := 6;  -- 64B region (word address = [ADDR_WIDTH-1:2])
       C_S_AXI_DATA_WIDTH		: integer := 32;
       FIFO_DEPTH				: integer := 256
    );
    port (
        -- Global clock/reset
        ACLK    				: in  std_logic;
        ARESETN 				: in  std_logic;												

        -- AXI4-Lite: Write Address
        S_AXI_AWADDR  			: in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_AWVALID 			: in  std_logic;
        S_AXI_AWREADY 			: out std_logic;

        -- AXI4-Lite: Write Data (WSTRB present per spec but ignored)															
        S_AXI_WDATA   			: in  std_logic_vector(31 downto 0);
        S_AXI_WSTRB   			: in  std_logic_vector(3 downto 0); -- ignored
        S_AXI_WVALID  			: in  std_logic;
        S_AXI_WREADY  			: out std_logic;

        -- AXI4-Lite: Write Response
        S_AXI_BRESP   			: out std_logic_vector(1 downto 0);
        S_AXI_BVALID  			: out std_logic;
        S_AXI_BREADY  			: in  std_logic;

        -- AXI4-Lite: Read Address
        S_AXI_ARADDR  			: in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_ARVALID 			: in  std_logic;
        S_AXI_ARREADY 			: out std_logic;

        -- AXI4-Lite: Read Data
        S_AXI_RDATA   			: out std_logic_vector(31 downto 0);
        S_AXI_RRESP   			: out std_logic_vector(1 downto 0);
        S_AXI_RVALID  			: out std_logic;
        S_AXI_RREADY  			: in  std_logic;

        -- ========= PDHS-facing ports (placeholders; not used inside yet) =========
        -- AXI4-Stream Slave (MM2S into PDHS)
        S_AXIS_TVALID 			: in  std_logic;
        S_AXIS_TDATA  			: in  std_logic_vector(7 downto 0);
        S_AXIS_TLAST  			: in  std_logic;
        S_AXIS_TREADY 			: out std_logic;

        -- AXI4-Stream Master (S2MM from PDHS)
        M_AXIS_TVALID 			: out std_logic;
        M_AXIS_TDATA  			: out std_logic_vector(7 downto 0);
        M_AXIS_TREADY 			: in  std_logic;
        M_AXIS_TLAST  			: out std_logic;
        M_AXIS_TKEEP  			: out std_logic_vector(0 downto 0);

        -- UART pins
        SIN         			: in  std_logic;
        TxEN					: in  std_logic;
        RxEn					: in  std_logic;
        SOUT        			: out std_logic
    );
end entity;

architecture rtl of axi_top is

    -- ===================
    -- Internal registers
    -- ===================
    signal r_baud_rate     		: std_logic_vector(31 downto 0) := (others => '0'); 
 	signal r_fclk_hz   			: std_logic_vector(31 downto 0) := (others => '0');
    signal r_frame_bytes     	: std_logic_vector(31 downto 0) := (others => '0');
	signal r_idle_flush_bytes	: std_logic_vector(31 downto 0) := (others => '0');
	signal r_clks_per_bit       : std_logic_vector(15 downto 0) := (others => '0');
	signal r_uart_tx_en			: std_logic_vector(31 downto 0);
	signal r_uart_rx_en			: std_logic_vector(31 downto 0);
	
    signal r_uart_tx_empty		: std_logic_vector(31 downto 0) := (others => '0');
    signal r_uart_tx_full	    : std_logic_vector(31 downto 0) := (others => '0');  
    signal r_uart_rx_empty		: std_logic_vector(31 downto 0) := (others => '0'); 
    signal r_uart_rx_full	    : std_logic_vector(31 downto 0) := (others => '0'); 	
    signal reg3          		: std_logic_vector(31 downto 0) := (others => '0');
    
    -- Ready output signals
    signal 	r_axi_awready		: std_logic;
    signal  r_axi_wready		: std_logic;
	signal  r_axi_rvalid		: std_logic;  
	signal  r_axi_arready		: std_logic;
	signal  r_axi_bvalid		: std_logic;
    
                         		
    -- ==============    		
    -- Write path        		
    -- ==============    		
    signal have_aw       		: std_logic := '0';  -- OWNED by AW process
    signal have_w        		: std_logic := '0';  -- OWNED by  W process
    signal awaddr_reg    		: std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal wdata_reg     		: std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0) := (others => '0');
    signal wr_go_pulse   		: std_logic := '0';  -- OWNED by W process (1-cycle)
                         		
    signal aw_hs         		: std_logic;  -- AWVALID & AWREADY
    signal w_hs          		: std_logic;  -- WVALID  & WREADY
    signal b_hs          		: std_logic;  -- BVALID  & BREADY
                         		
    -- ==============    		
    -- Read path         		
    -- ==============    		
    signal have_ar       		: std_logic := '0';  -- OWNED by AR process
    signal araddr_reg    		: std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0) := (others => '0');
                         		
    signal ar_hs         		: std_logic;  -- ARVALID & ARREADY
    signal r_hs          		: std_logic;  -- RVALID  & RREADY

begin

	--====================================================================
	-- Outputs
	--====================================================================
	S_AXI_AWREADY		<= r_axi_awready;		
	S_AXI_WREADY        <= r_axi_wready;     
	S_AXI_RVALID        <= r_axi_rvalid;     
	S_AXI_ARREADY       <= r_axi_arready;
	S_AXI_BVALID    	<= r_axi_bvalid;
	
    -- ---------------
    -- Handshakes
    -- ---------------
    aw_hs <= S_AXI_AWVALID and r_axi_awready;
    w_hs  <= S_AXI_WVALID  and r_axi_wready;	    
    b_hs  <= r_axi_bvalid  and S_AXI_BREADY;	    

    ar_hs <= S_AXI_ARVALID and r_axi_arready;
    r_hs  <= r_axi_rvalid  and S_AXI_RREADY; 

    -- ---------------
    -- User taps
    -- ---------------
    --reg0_o <= reg0;
    --reg1_o <= reg1;
    --reg2_o <= reg2;
    --reg3_o <= reg3;

    -- ====================================================
    -- AW channel process (sole owner of have_aw & AWREADY)
    -- ====================================================
    process (ACLK)
    begin
        if rising_edge(ACLK) then
            if ARESETN = '0' then
                r_axi_awready <= '0';
                have_aw       <= '0';
                awaddr_reg    <= (others => '0');
            else
                -- Backpressure: ready only when not holding an address
                r_axi_awready <= not have_aw;

                if aw_hs = '1' then
                    awaddr_reg <= S_AXI_AWADDR;
                    have_aw    <= '1';
                elsif wr_go_pulse = '1' then
                    -- Clear once the write is committed in B process
                    have_aw    <= '0';
                end if;
            end if;
        end if;
    end process;

    -- =====================================================
    -- W channel process (sole owner of have_w & wr_go_pulse)
    -- =====================================================
    process (ACLK)
    begin
        if rising_edge(ACLK) then
            if ARESETN = '0' then
                r_axi_wready <= '0';
                have_w       <= '0';
                wdata_reg    <= (others => '0');
                wr_go_pulse  <= '0';
            else
                -- default: pulse low
                wr_go_pulse  <= '0';

                -- Backpressure: ready only when not holding data
                r_axi_wready <= not have_w;

                if w_hs = '1' then
                    wdata_reg <= S_AXI_WDATA;  -- WSTRB ignored on purpose
                    have_w    <= '1';
                end if;

                -- Fire a write when address + data are both latched
                if (have_aw = '1') and (have_w = '1') and (r_axi_bvalid = '0') then
                    wr_go_pulse <= '1';
                    have_w      <= '0';  -- release W slot
                end if;
            end if;
        end if;
    end process;

    -- ============================================
    -- B channel process (writes regs + sends BRESP)
    -- ============================================
    process (ACLK)
        variable waddr : unsigned(C_S_AXI_ADDR_WIDTH-1 downto 2);
    begin
        if rising_edge(ACLK) then
            if ARESETN = '0' then
                r_axi_bvalid <= '0';
                S_AXI_BRESP  <= (others => '0'); -- OKAY
            else
                if wr_go_pulse = '1' then
                    -- decode word address
                    waddr := unsigned(awaddr_reg(awaddr_reg'left downto 2));
                    case to_integer(waddr) is
                        when 0 => r_baud_rate 			<= wdata_reg;
                        when 1 => r_frame_bytes 		<= wdata_reg;
                        when 2 => r_idle_flush_bytes 	<= wdata_reg;
                        when 3 => r_uart_tx_en          <= wdata_reg;
                        when 4 => r_uart_rx_en			<= wdata_reg;
                        when 5 => r_fclk_hz				<= wdata_reg;	
                        when others => null; -- writes to unmapped addrs are ignored
                    end case;

                    r_axi_bvalid <= '1';
                    S_AXI_BRESP  <= "00"; -- OKAY
                elsif b_hs = '1' then
                    r_axi_bvalid <= '0';
                end if;
            end if;
        end if;
    end process;

    -- ====================================================
    -- AR channel process (sole owner of have_ar & ARREADY)
    -- ====================================================
    process (ACLK)
    begin
        if rising_edge(ACLK) then
            if ARESETN = '0' then
                r_axi_arready <= '0';
                have_ar       <= '0';
                araddr_reg    <= (others => '0');
            else
                -- Backpressure: ready only when not holding an address
                r_axi_arready <= not have_ar;

                if ar_hs = '1' then
                    araddr_reg <= S_AXI_ARADDR;
                    have_ar    <= '1';
                elsif r_hs = '1' then
                    have_ar    <= '0';
                end if;
            end if;
        end if;
    end process;

    -- ======================================
    -- R channel process (returns read data)
    -- ======================================
    process (ACLK)
        variable raddr : unsigned(C_S_AXI_ADDR_WIDTH-1 downto 2);
    begin
        if rising_edge(ACLK) then
            if ARESETN = '0' then
                r_axi_rvalid <= '0';
                S_AXI_RDATA  <= (others => '0');
                S_AXI_RRESP  <= (others => '0'); -- OKAY
            else
                if (have_ar = '1') and (r_axi_rvalid = '0') then
                    raddr := unsigned(araddr_reg(araddr_reg'left downto 2));
                    case to_integer(raddr) is
                        when 6 		=> S_AXI_RDATA <= r_uart_tx_empty;		-- TX EMPTY 
                        when 7 		=> S_AXI_RDATA <= r_uart_tx_full;		-- TX FULL
                        when 8 		=> S_AXI_RDATA <= r_uart_rx_empty;		-- RX EMPTY
                        when 9 		=> S_AXI_RDATA <= r_uart_rx_full;		-- RX FULL
                        when others => S_AXI_RDATA <= (others => '0');
                    end case;
                    r_axi_rvalid <= '1';
                    S_AXI_RRESP  <= "00"; -- OKAY
                elsif r_hs = '1' then
                    r_axi_rvalid <= '0';
                end if;
            end if;
        end if;
    end process;
        
    --====================================================================
    -- PDHS_TOP Instantce 
    --====================================================================
    Inst_UART_STREAM_TOP : entity work.UART_STREAM_TOP
    	generic map (
    	    FIFO_DEPTH				=> FIFO_DEPTH
    	)	
    	port map (
    	    AXI_ACLK      			=> ACLK,    
    	    AXI_ARESETN   			=> ARESETN, 
    	    											
    	    -- AXI4-Stream slave interface												             
    	    S_AXI_TVALID    		=> S_AXIS_TVALID,
    	    S_AXI_TDATA     		=> S_AXIS_TDATA, 
    	    S_AXI_TLAST     		=> S_AXIS_TLAST,  	
    	    S_AXI_TREADY    		=> S_AXIS_TREADY,
    	                                                                                                                                                  
    	    -- AXI4-Stream Master (from UART Rx)
    	    M_AXIS_TVALID			=> M_AXIS_TVALID,
    	    M_AXIS_TDATA			=> M_AXIS_TDATA,  		
    	    M_AXIS_TREADY			=> M_AXIS_TREADY, 		
    	    M_AXIS_TLAST			=> M_AXIS_TLAST,  		
    	    M_AXIS_TKEEP 			=> M_AXIS_TKEEP,  		
    	                                                                                                                                             
    	    --Rx FIFO status
    	    o_FIFO_COUT				=> open,          --: out std_logic_vector(15 downto 0);      
			o_FIFO_OVERFLOW 		=> open,          --: out std_logic; 
			o_FIFO_FRAME_COUTN      => open,          --: out std_logic_vector(31 downto 0);	
			-- Control Line 
			i_FRAME_BYTES           => r_frame_bytes(15 downto 0),     
			i_IDLE_FLUSH_BYTES	    => r_idle_flush_bytes(7 downto 0),
			i_CLKS_PER_BIT    	    => r_clks_per_bit, 
			 
			i_UART_TX_EN			=> r_uart_tx_en(0),
			i_UART_RX_EN			=> r_uart_rx_en(0),
			
			-- FIFO Status signal                   	
			O_TX_FIFO_EMPTY			=> r_uart_tx_empty(0),
			O_TX_FIFO_FULL			=> r_uart_tx_full(0), 
			
			O_RX_FIFO_EMPTY			=> r_uart_rx_empty(0), 
			O_RX_FIFO_FULL			=> r_uart_rx_full(0),	
				         
    	    -- Optionally: outputs for user logic
    	    i_Sin 					=> SIN,
    	    o_Sout					=> SOUT
    	);

	--====================================================================
    -- Baud Rate selection module Instantce 
    --====================================================================
	Inst_baud_to_clks_per_bit_cont : entity work.baud_to_clks_per_bit_conf
    	generic map (
    	    OUT_WIDTH 			=> 16,				-- clks per bit output width, 16 bit could be 32 as well
    	    DEFAULT_CPB  		=> 868
    	)                  	
    	port map (              	
    	    i_fclk_hz      		=> r_fclk_hz,		-- e.g., 100_000_000 from PS
    	    i_baud_val     		=> r_baud_rate,		-- e.g., 9600, 115200
    	    o_clks_per_bit 		=> r_clks_per_bit
    	);
	
	                                             


end architecture;



