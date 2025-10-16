----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 06/27/2025 12:29:27 PM
-- Design Name: 
-- Module Name: Uart_stream_TOP - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity UART_STREAM_TOP is
	generic (
		FIFO_DEPTH				: integer := 256
	);
    port (
        AXI_ACLK      			: in  std_logic;
        AXI_ARESETN   			: in  std_logic;
        
        -- AXI4-Stream slave interface
        S_AXI_TVALID    		: in  std_logic;
        S_AXI_TDATA     		: in  std_logic_vector(7 downto 0);
        S_AXI_TLAST     		: in  std_logic;
        S_AXI_TREADY    		: out std_logic;    		-- tie to fifo ready
        
        -- AXI4-Stream Master (from UART Rx)
        M_AXIS_TVALID			: out std_logic;
        M_AXIS_TDATA			: out std_logic_vector(7 downto 0);
        M_AXIS_TREADY			: in  std_logic;
        M_AXIS_TLAST			: out std_logic;
        M_AXIS_TKEEP 			: out std_logic_vector(0 downto 0);
        
        --Rx FIFO status
        o_FIFO_COUT				: out std_logic_vector(15 downto 0);      
		o_FIFO_OVERFLOW 		: out std_logic; 
		o_FIFO_FRAME_COUTN      : out std_logic_vector(31 downto 0);
			
		-- Control Line
		--i_BAUD_RATE				: in  std_logic_vector( 2 downto 0);	
		i_FRAME_BYTES           : in  std_logic_vector(15 downto 0);
		i_IDLE_FLUSH_BYTES	    : in  std_logic_vector( 7 downto 0);
		i_CLKS_PER_BIT    	    : in  std_logic_vector(15 downto 0);
			
		i_UART_TX_EN			: in  std_logic;
		i_UART_RX_EN			: in  std_logic;
		
		-- FIFO Status signal 
		O_TX_FIFO_EMPTY			: out std_logic;
		O_TX_FIFO_FULL			: out std_logic;  
		
		O_RX_FIFO_EMPTY			: out std_logic;
		O_RX_FIFO_FULL		    : out std_logic;     
		
        -- Optionally: outputs for user logic
        i_Sin 					: in std_logic;
        o_Sout					: out std_logic
    );
end entity;

architecture rtl of UART_STREAM_TOP is
	
-- AXI Steam FIFO
component tx_fifo is
    generic (
        FIFO_DEPTH 				: integer := 256  -- Must be power of 2
    );
    port (
        CLK   					: in  std_logic;
        RSTn   					: in  std_logic;

        -- AXI4-Stream Slave interface (input)
        S_AXIS_TVALID 			: in  std_logic;
        S_AXIS_TREADY 			: out std_logic;
        S_AXIS_TDATA  			: in  std_logic_vector(7 downto 0);
        S_AXIS_TLAST			: in  std_logic;

        -- AXI4-Stream Master interface (output)
        M_AXIS_TVALID 			: out std_logic;
        M_AXIS_TREADY 			: in  std_logic;
        M_AXIS_TDATA  			: out std_logic_vector(7 downto 0);
        
        empty					: out std_logic;
        full					: out std_logic	
								 								        	
    );
end component;
	
COMPONENT TxFIFO
  	PORT (
  	  	clk 					: IN  STD_LOGIC;
  	  	srst 					: IN  STD_LOGIC;
  	  	din 					: IN  STD_LOGIC_VECTOR(7 DOWNTO 0);
  	  	wr_en 					: IN  STD_LOGIC;
  	  	rd_en 					: IN  STD_LOGIC;
  	  	dout 					: OUT STD_LOGIC_VECTOR(7 DOWNTO 0);
  	  	full 					: OUT STD_LOGIC;
  	  	empty 					: OUT STD_LOGIC 
  	);
END COMPONENT;	
	
component UART_TX
    port (
        i_Clk           		: in  std_logic;
        i_RSTN          		: in  std_logic;
        
        -- enable TX (active high). When '0', TX is idle and ignores i_TX_DV.
        i_TX_EN         		: in  std_logic; 		-- active log	
                        		
        i_CLKS_PER_BIT      	: in  std_logic_vector(15 downto 0);  
                        		
        i_TX_DV         		: in  std_logic;
        i_TX_Byte       		: in  std_logic_vector(7 downto 0);
        o_TX_Active     		: out std_logic;
        o_TX_Serial     		: out std_logic;
        o_TX_Done       		: out std_logic;
        o_TX_Ready      		: out std_logic
    );
end component;	
	
component UART_RX
  	--generic (                                                                
  	--  	g_CLKS_PER_BIT 	: integer := 868     -- Needs to be set correctly       
  	--);                                                                     
  	port (                                                                   
  	  	i_Clk       			: in  std_logic;
  	  	i_RSTN					: in  std_logic; 
  	  	
  	  	i_RX_EN					: in  std_logic;
  	  	
  	  	i_CLKS_PER_BIT			: in  std_logic_vector(15 downto 0);                                          
  	  	i_RX_Serial 			: in  std_logic;                                           
  	  	o_RX_DV     			: out std_logic;                                           
  	  	o_RX_Byte   			: out std_logic_vector( 7 downto 0)                         
  	);                                                                     
end component;  


	
	signal r_dma_tvalid 		: std_logic := '0';    
	signal r_dma_data			: std_logic_vector(7 downto 0) := (others => '0');      
	                        	
	signal r_fifo_tvalid    	: std_logic := '0';                               
	signal r_x_tready    		: std_logic := '0';                               
	signal r_fifo2TxUart_data	: std_logic_vector(7 downto 0) := (others => '0');
	
	--UART Tx serial output
	signal r_uart_tx_sout		: std_logic; 
	signal r_uart_rx_sin		: std_logic;
	signal r_uart_tx_done		: std_logic := '0';
	signal r_uart_tx_ready		: std_logic := '0';
	signal r_UART_TX_DV			: std_logic := '0';
	signal r_tx_fifo_empty      : std_logic := '0';   
	signal r_tx_fifo_full 		: std_logic := '0';
	signal uart_tx_byte			: std_logic_vector(7 downto 0);
	signal r_uart_ready			: std_logic;
			
	-- UART Rx signals
	signal r_rx_uart_dv			: std_logic;
	signal r_rx_uart_byte		: std_logic_vector(7 downto 0);  
	signal r_rx_fifo_count		: unsigned(15 downto 0);
	signal r_rx_fifo_axis_tvalid: std_logic := '0';  
	signal r_rx_fifo_axis_tdata : std_logic_vector(7 downto 0);
	signal r_rx_fifo_axis_tlast : std_logic := '0';
	
	-- Wires to connect 
	signal w_fifo_ready			: std_logic := '0';	
	signal r_uart_tx_active		: std_logic:= '0';
	
	 -- FSM signals
    constant	s_IDLE				: std_logic_vector(3 downto 0) := "0001";
	constant	s_READ				: std_logic_vector(3 downto 0) := "0010";
	constant	s_LOAD				: std_logic_vector(3 downto 0) := "0100";
	constant	s_WAIT				: std_logic_vector(3 downto 0) := "1000";
	
	signal		tx_current_state	: std_logic_vector(4 downto 1) := s_IDLE;
	signal		tx_next_state		: std_logic_vector(4 downto 1) ;
	
	signal		s_state_1			: std_logic;
	signal		s_state_2			: std_logic;
	signal		s_state_3			: std_logic;
	signal		s_state_4			: std_logic;
	
		
begin
	
	----------------------------------------------------
	-- Output signals
	----------------------------------------------------
	M_AXIS_TVALID  	<= r_rx_fifo_axis_tvalid;	               
	M_AXIS_TDATA	<= r_rx_fifo_axis_tdata; 	               
	M_AXIS_TLAST	<= r_rx_fifo_axis_tlast; 
	
	-- Fifo status signals
	O_TX_FIFO_EMPTY	<=   r_tx_fifo_empty;
	O_TX_FIFO_FULL	<=   r_tx_fifo_full;   
	-- UART In/Out signal    
    r_uart_rx_sin  	<=  i_Sin ;		
	o_Sout			<=  r_uart_tx_sout;
	----------------------------------------------------
    -- FIFO Ready OUTPUT
    ----------------------------------------------------
	S_AXI_TREADY <= w_fifo_ready;   
	--o_FIFO_COUT  <= std_logic_vector(r_rx_fifo_count); 

    -- Simple handshake: latch data when valid
    process(AXI_ACLK)
    begin
        if rising_edge(AXI_ACLK) then
            if AXI_ARESETN = '0' then      
            	r_dma_tvalid   	<= '0';          
            else
            	if S_AXI_TVALID = '1' then
                	-- Assign fifo signal 
                    r_dma_tvalid   	<= '1';
                    r_dma_data		<= S_AXI_TDATA;
                else                
                    r_dma_tvalid   	<= '0';
                end if;
            end if;
        end if;
    end process;
    
    --------------------------------------------------------
    --  AXIS FIFO Instance
    --------------------------------------------------------
	Inst_axis_fifo : tx_fifo
    generic map (
        FIFO_DEPTH 				=> FIFO_DEPTH  -- Must be power of 2
    )                       	
    port map (              	
        CLK   					=> AXI_ACLK,
        RSTn   					=> AXI_ARESETN,
    
        -- AXI4-Stream Slave interface (input)
        S_AXIS_TVALID 			=> r_dma_tvalid,
        S_AXIS_TREADY 			=> w_fifo_ready,
        S_AXIS_TDATA  			=> r_dma_data,
        S_AXIS_TLAST			=> '0',
    
        -- AXI4-Stream Master interface (output)
        M_AXIS_TVALID 			=> r_fifo_tvalid,
        M_AXIS_TREADY 			=> r_uart_tx_ready,
        M_AXIS_TDATA  			=> r_fifo2TxUart_data,
        
        empty					=> r_tx_fifo_empty,
        full					=> r_tx_fifo_full
    );

	--===============================================================
	-- FSM to control over TX FIFO 
	--===============================================================
	process (AXI_ACLK, AXI_ARESETN, tx_next_state)
	begin
  		if(rising_edge(AXI_ACLK)) then
  			if (AXI_ARESETN = '0') then
  				tx_current_state <= s_IDLE; 
  			else
				tx_current_state <= tx_next_state; 
			end if;
  		end if;
	end process;
	
	-- If there is data in the FIFO, it attempts transmission unconditionally.
	process(tx_current_state, r_tx_fifo_empty, r_uart_tx_done)
	begin
		tx_next_state	<=	s_IDLE;
		case tx_current_state is
			when s_IDLE =>  						-- "0001"
				if (r_tx_fifo_empty = '0') then  
					tx_next_state	<= s_READ;
				else
					tx_next_state <= s_IDLE;
				end if;
        	
			when s_READ =>							-- "0010"				--	Generates the FIFO read control signal.
				tx_next_state	 	<= s_LOAD;
        	
			when s_LOAD =>							-- "0100"				--	Loads the 1-byte data read from the FIFO into the TSR register.
				tx_next_state 		<= s_WAIT;								--	The FIFO read cycle must be 1 cycle. 
        	
			when s_WAIT =>							-- "1000"				--	Performs a 10-bit transmission. 
				if (r_uart_tx_done = '1') then
					tx_next_state  <= s_IDLE;
				else
					tx_next_state	<= s_WAIT;
				end if;
        	
			when others =>
				tx_next_state <= s_IDLE;			-- "0001"
        	
		end case;
	end process;
	
	r_uart_tx_ready	<=	'1' when tx_current_state = s_LOAD else '0'; -- s_READ commented
	
	--=======================================================
    -- Tx FIFO to UART Trigger Logic
    --=======================================================
    process(AXI_ACLK, AXI_ARESETN)
    begin
        if rising_edge(AXI_ACLK) then
            if AXI_ARESETN = '0' then
                r_UART_TX_DV     		<= '0';
                uart_tx_byte			<= (others => '0');
            else
               if tx_current_state = s_LOAD then
                	r_UART_TX_DV      	<= '1';  
                	uart_tx_byte     	<= r_fifo2TxUart_data;
                else           	
                    r_UART_TX_DV     	<= '0';
                end if;
            end if;
        end if;
    end process;
	
	
	Inst_UART_TX : UART_TX
    	port map (
    	    i_Clk           	=> AXI_ACLK,   
    	    i_RSTN          	=> AXI_ARESETN,
    	    
    	    i_TX_EN         	=> i_UART_TX_EN,
    	                    	
    	    i_CLKS_PER_BIT      => i_CLKS_PER_BIT, 
    	                    	
    	    i_TX_DV         	=> r_UART_TX_DV,
    	    i_TX_Byte       	=> uart_tx_byte,
    	    o_TX_Active     	=> r_uart_tx_active,
    	    o_TX_Serial     	=> r_uart_tx_sout,    -- UART TX is looped to UART RX i_RX_Serial 
    	    o_TX_Done       	=> r_uart_tx_done,
    	    o_TX_Ready      	=> r_uart_ready
    	);
	--=======================================================
    -- Rx UART to rx_fifo 
    --=======================================================
    
    Inst_UART_RX : UART_RX
  		port map (                                                                   
  		  	i_Clk       		=> AXI_ACLK,
  		  	i_RSTN				=> AXI_ARESETN,
  		  	
  		  	i_RX_EN				=> i_UART_RX_EN,
  		  	
  		  	i_CLKS_PER_BIT		=> i_CLKS_PER_BIT, -- "100",
  		  	
  		  	i_RX_Serial 		=> r_uart_rx_sin,   --r_uart_tx_sout, r_uart_rx_sin
  		  	o_RX_DV     		=> r_rx_uart_dv,
  		  	o_RX_Byte   		=> r_rx_uart_byte
  		);        
  	
  	Inst_flush_cfg : entity work.rx_fifo_axis_flush_cfg
  	  	generic map (
  	  	    FIFO_DEPTH 			=> FIFO_DEPTH  -- power-of-2 recommended
  	  	)
  	  	port map(
  	  	    CLK                	=> AXI_ACLK,    
  	  	    RSTn               	=> AXI_ARESETN, 
  	  	
  	  	    -- UART RX byte interface
  	  	    i_rx_dv            	=> r_rx_uart_dv,       -- 1-cycle pulse per received byte
  	  	    i_rx_byte          	=> r_rx_uart_byte,
  	  	
  	  	    -- AXI4-Stream Master (to AXI DMA S2MM)
  	  	    M_AXIS_TVALID      	=> r_rx_fifo_axis_tvalid,  
  	  	    M_AXIS_TREADY      	=> M_AXIS_TREADY,    	-- Ready signal from DMA          
  	  	    M_AXIS_TDATA       	=> r_rx_fifo_axis_tdata,   
  	  	    M_AXIS_TKEEP       	=> M_AXIS_TKEEP,           
  	  	    M_AXIS_TLAST       	=> r_rx_fifo_axis_tlast,   
  	  	
  	  	    -- Status / debug
  	  	    fifo_count         	=> r_rx_fifo_count, 		
  	  	    overflow           	=> o_FIFO_OVERFLOW, 		-- sticky overflow (RX byte dropped)
  	  	    frame_count        	=> open,   
  	  	    
  	  	    o_fifo_empty		=> O_RX_FIFO_EMPTY,
        	o_fifo_full         => O_RX_FIFO_FULL,
  	  	
  	  	    -- Runtime configuration
  	  	    i_frame_bytes      	=> i_FRAME_BYTES,            -- bytes per normal TLAST frame
  	  	    i_idle_flush_bytes 	=> i_IDLE_FLUSH_BYTES,	    -- UART byte-times before flushing partial
  	  	    i_clks_per_bit     	=> i_CLKS_PER_BIT    	    -- fabric clocks per UART bit
  	  	);

    
	-- ILA Instantce 
	--Inst_ila_0 : entity work.ila_0
	--	port map (
	--		clk 				=> AXI_ACLK,
	--		probe0 				=> r_dma_data, --uart_tx_byte,
	--		probe1(0)			=> r_dma_tvalid, --r_tx_fifo_empty,
	--		probe2(0)			=> r_uart_ready,
	--		probe3 				=> r_rx_fifo_axis_tdata, --r_dma_data,
	--		probe4(0)			=> r_rx_fifo_axis_tvalid, --r_uart_tx_done,
	--		probe5(0)			=> M_AXIS_TREADY,
	--		probe6(0) 			=> r_UART_TX_DV,
	--		probe7(0) 			=> r_rx_fifo_axis_tlast
	--	);	
	
	
end architecture;