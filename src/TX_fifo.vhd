library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tx_fifo is
    generic (
        FIFO_DEPTH 			: integer := 256  -- Must be power of 2
    );
    port (
        CLK   				: in  std_logic;
        RSTn   				: in  std_logic;

        -- AXI4-Stream Slave interface (input)
        S_AXIS_TVALID 		: in  std_logic;
        S_AXIS_TREADY 		: out std_logic;
        S_AXIS_TDATA  		: in  std_logic_vector(7 downto 0);
        S_AXIS_TLAST		: in  std_logic; 

        -- AXI4-Stream Master interface (output)
        M_AXIS_TVALID 		: out std_logic;
        M_AXIS_TREADY 		: in  std_logic;
        M_AXIS_TDATA  		: out std_logic_vector(7 downto 0);
        
        -- FIFO control signals 
        empty				: out std_logic;
        full				: out std_logic
    );
end entity;

architecture rtl of tx_fifo is

    -- Internal FIFO signals
    type fifo_mem_t is array (0 to FIFO_DEPTH-1) of std_logic_vector(7 downto 0);
    signal fifo_mem : fifo_mem_t;

    signal wr_ptr 			: integer range 0 to FIFO_DEPTH-1 := 0;
    signal rd_ptr 			: integer range 0 to FIFO_DEPTH-1 := 0;
                        	
    signal fifo_count 		: integer range 0 to FIFO_DEPTH := 0;
                        	
    signal wr_en 			: std_logic;
    signal rd_en 			: std_logic;  
    
    signal r_axis_tready 	: std_logic;   
    signal r_axis_tvalid 	: std_logic; 
    
    signal r_fifo2uart_data : std_logic_vector(7 downto 0);
    	
    signal sEmpty			: std_logic ;	
    signal sFull			: std_logic ;	
    


begin
	
	-- Output assign
	M_AXIS_TVALID 	<= r_axis_tvalid;
	S_AXIS_TREADY 	<= r_axis_tready;
	M_AXIS_TDATA	<= r_fifo2uart_data;
	empty 			<= sEmpty; 
	full			<= sFull;
	
    -- Write enable when valid and ready
    wr_en <= '1' when (S_AXIS_TVALID = '1' and r_axis_tready = '1') else '0';

    -- Read enable when downstream ready and data available
    rd_en <= '1' when (M_AXIS_TREADY = '1' and r_axis_tvalid = '1') else '0';

    -- Input: S_AXIS_TREADY is high when FIFO is not full
    r_axis_tready <= '1' when (fifo_count < FIFO_DEPTH) or
                          	 ((fifo_count = FIFO_DEPTH) and (M_AXIS_TREADY = '1' and fifo_count > 0))
                 else '0';	

    -- Output: M_AXIS_TVALID is high when FIFO is not empty
    r_axis_tvalid <= '1' when fifo_count > 0 else '0';

    -- Drive output data from FIFO read pointer
    r_fifo2uart_data <= fifo_mem(rd_ptr);
    
    -- FIFO Flags	
    sEmpty <= '1' when fifo_count = 0 else '0';
	sFull  <= '1' when fifo_count = FIFO_DEPTH else '0';	
		

    -- Sequential process: write and read logic
    process(CLK)
    begin
        if rising_edge(CLK) then
            if RSTn = '0' then
                wr_ptr <= 0;
                rd_ptr <= 0;
                fifo_count <= 0;
            else
                -- Write operation updated	
                if wr_en = '1' then
  					if wr_ptr = FIFO_DEPTH-1 then 
  						wr_ptr <= 0; 
  					else 
  						wr_ptr <= wr_ptr + 1; 
  					end if;
				end if;	

                -- Read operation updated
                if rd_en = '1' then
  					if rd_ptr = FIFO_DEPTH-1 then 
  						rd_ptr <= 0; 
  					else 
  						rd_ptr <= rd_ptr + 1; 
  					end if;
				end if;
                
                -- Keep track of the total number of words in the FIFO
                	
                if wr_en = '1' and rd_en = '0' then
                	fifo_count <= fifo_count + 1;
                elsif wr_en = '0' and rd_en = '1'then
                	fifo_count <= fifo_count - 1;
                else
                	fifo_count <= fifo_count; 
               	end if;	
                	
            end if;
        end if;
    end process;

	---- ILA Instantce 
	--Inst_ila_2 : entity work.ila_2
	--	port map (
	--		clk 				=> CLK,
	--		probe0 				=> S_AXIS_TDATA,   	-- s_FIFO tdata
	--		probe1(0)			=> S_AXIS_TVALID,   -- s_FIFO tvalid
	--		probe2(0)			=> r_axis_tready,   -- s_FIFO tready
	--		probe3 				=> r_fifo2uart_data,-- m_FIFO tdata 
	--		probe4(0)			=> r_axis_tvalid,	-- m_FIFO tvalid
	--		probe5(0)			=> M_AXIS_TREADY,	-- m_FIFO tready
	--		probe6(0) 			=> wr_en,
	--		probe7(0) 			=> sFull,
	--		probe8				=> std_logic_vector(to_unsigned(fifo_count,8)),
	--		probe9(0)			=> sEmpty
	--	);	
	--
end architecture;
    

                                                                  

                                   