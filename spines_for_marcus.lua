----------------------------------------------------------
--  Example script for simulation on 3d spine model		--
--														--
--  Author:	Markus Breit								--
--  Date:	21-08-2014									--
----------------------------------------------------------

-- load pre-implemented lua functions
ug_load_script("ug_util.lua")

-- dimension
dim = 3

-- initialize ug with dimension and algebra
InitUG(dim, AlgebraType("CPU", 1));
--EnableLUA2C(true)	-- speed up evaluation of lua functions by c program
--SetDebugLevel(debugID.LUACompiler, 0) 

------------------------------------------------
-- get parameters from command line arguments --
------------------------------------------------

-- choice of grid
gridName = util.GetParam("-grid", "spines/normSpine.ugx")

-- total refinements
numRefs = util.GetParamNumber("-numRefs", 0)

-- choose length of maximal time step during the whole simulation
timeStep = util.GetParamNumber("-tstep", 0.01)

-- choose length of time step at the beginning (often needs to be smaller than timestep)
timeStepStart = util.GetParamNumber("-tstepStart", timeStep)

-- if not timeStepStart = 2^(-n)*timeStep, take nearest lower number of that form
function log2(x)
	return math.log(x)/math.log(2)
end
startLv =  math.ceil(log2(timeStep/timeStepStart))
timeStepStartNew = timeStep / math.pow(2, startLv)
if (math.abs(timeStepStartNew-timeStepStart)/timeStepStart > 1e-5) then 
	print("timeStepStart argument ("..timeStepStart..") was not admissible; taking "..timeStepStartNew.." instead.")
end
timeStepStart = timeStepStartNew
	
-- choose end time or number of timesteps
endTime = util.GetParamNumber("-endTime")
if (endTime == nil)
then
	-- choose number of time steps
	nTimeSteps = util.GetParamNumber("-nTimeSteps", 1)
	endTime = nTimeSteps*timeStep
end


-- specify -vtk to generate vtk output
generateVTKoutput = util.HasParamOption("-vtk")

-- choose plotting interval for vtk output (standard is timeStep)
plotStep = util.GetParamNumber("-pstep", timeStep)

-- choose solver setup
-- (I recommend using the standard, GS, which has proved to be fastest and most stable)
solverID = util.GetParam("-solver", "GS")
solverID = string.upper(solverID)
validSolverIDs = {}
validSolverIDs["GMG-GS"] = 0;
validSolverIDs["GMG-ILU"] = 0;
validSolverIDs["GMG-LU"] = 0;
validSolverIDs["GS"] = 0;
validSolverIDs["ILU"] = 0;
validSolverIDs["JAC"] = 0;
if (validSolverIDs[solverID] == nil) then
    error("Unknown solver identifier " .. solverID)
end
 
-- choose directory for output file (needs to exist)
fileName = util.GetParam("-outName", "spine_sims")
fileName = fileName.."/"

---------------
-- constants --
---------------
-- total cytosolic calbindin concentration
-- (four times the real value in order to simulate four binding sites in one)
totalClb = 4*40.0e-6

-- diffusion coefficients
D_cac = 220.0
D_cae = 220.0
D_ip3 = 280.0
D_clb = 20.0

-- calbindin binding rates
k_bind_clb = 	27.0e06
k_unbind_clb = 	19

-- initial concentrations
ca_cyt_init = 5.0e-08 --4.0e-8
ca_er_init = 2.5e-4
ip3_init = 4.0e-8
clb_init = totalClb / (k_bind_clb/k_unbind_clb*ca_cyt_init + 1) -- equilibrium conc.

-- reaction reate IP3
reactionRateIP3 = 0.11

-- equilibrium concentration IP3
equilibriumIP3 = 4.0e-08

-- reation term IP3
reactionTermIP3 = -reactionRateIP3 * equilibriumIP3

---------------------------------------------------------------------
-- functions steering tempo-spatial parameterization of simulation --
---------------------------------------------------------------------

-- density function for IP3R channels in the ER/spine apparatus membrane
function IP3Rdensity(x,y,z,t,si)
	return 17.3
end

-- density function for RyR channels in the ER/spine apparatus membrane
function RYRdensity(x,y,z,t,si)
	-- no ryrs in spine apparatus membrane
	-- (as it turns out, there might yet be RyRs in the spine apparatus, so do not hesitate to deactivate this condition)
	if (si == 8) then return 0.0 end
	return 0.86
end

-- density function for SERCA pumps in ER/spine apparatus membrane
-- this is a little bit more complicated, since it must be ensured that
-- the net flux for equilibrium concentrations is zero
-- MUST be adapted whenever any parameterization of ER flux mechanisms is changed!
function SERCAdensity(x,y,z,t,si)
	local v_s = 6.5e-27						-- V_S param of SERCA pump
	local k_s = 1.8e-7						-- K_S param of SERCA pump
	local j_ip3r = 3.7606194166520605e-23 -- 2.7817352713488838e-23	-- single channel IP3R flux (mol/s) - to be determined via gdb
	local j_ryr = 1.1204582669024472e-21 -- 4.6047720062808216e-22	-- single channel RyR flux (mol/s) - to be determined via gdb
	local j_leak = ca_er_init-ca_cyt_init	-- leak proportionality factor
	
	local dens =  IP3Rdensity(x,y,z,t,si) * j_ip3r
				+ RYRdensity(x,y,z,t,si) * j_ryr
				+ LEAKERconstant(x,y,z,t,si) * j_leak
	dens = dens / (v_s/(k_s/ca_cyt_init+1.0)/ca_er_init)
	
	return dens
end

-- function for ER/spine apparatus membrane leakage flux density
function LEAKERconstant(x,y,z,t,si)
	return 3.8e-17 --3.4e-17
end

-- density function for PMCA pumps in plasma membrane
function PMCAdensity(x,y,z,t,si)
	return 500.0
end

-- density function for NCX pumps in plasma membrane
function NCXdensity(x,y,z,t,si)
	return 15.0
end

-- density function for voltage gated calcium channels in plasma membrane
function VGCCdensity(x,y,z,t,si)
	return 1.0
end

-- function for leakage flux density through plasma membrane
function LEAKPMconstant(x,y,z,t,si)
	local j_pmca = - 6.9672131147540994e-24 -- - 5.230769230769231e-24	-- single pump PMCA flux (mol/s) - to be determined via gdb
	local j_ncx = - 6.7567567567567566e-23 -- - 5.4347826086956515e-23	-- single pump NCX flux (mol/s) - to be determined via gdb
	local j_vgcc = 1.5752042094823713e-25	-- single channel VGCC flux (mol/s) - to be determined via gdb
				-- *1.5 / * 0.5 for L-type / T-type
	local flux =  PMCAdensity(x,y,z,t,si) * j_pmca
				+ NCXdensity(x,y,z,t,si) * j_ncx
				+ VGCCdensity(x,y,z,t,si) * j_vgcc
	
	--if (-flux < 0) then error("PM leak flux is outward for these density settings!") end
	return -flux -- 6.85e-22
end


-- firing pattern of the synapse
syns = {}
synStart = 9
synStop = 9
caEntryDuration = 0.01
for i=synStart,synStop do
	syns[i] = 0.005*(i-synStart)
end

-- burst of calcium influx for active synapses (~1200 ions)
freq = 50      -- spike train frequency (Hz) (the ineq. 1/freq > caEntryDuration must hold)
nSpikes = 10   -- number of spikes	
function ourNeumannBndCA(x, y, z, t, si)	
	-- spike train
	if (si>=synStart and si<=synStop and t <= syns[si] + caEntryDuration + (nSpikes - 1) * 1.0/freq) then
        t = t % (1.0/freq)
	end --> now, treat like single spike
	
	-- single spike
	if 	(si>=synStart and si<=synStop and syns[si]<t and t<=syns[si]+caEntryDuration)
	then influx = 2e-4
	else influx = 0.0
	end
	
    return influx
end


-- burst of ip3 at active synapse (triangular, immediate)
ip3EntryDelay = 0.000
ip3EntryDuration = 2.0
corrFact = -10.4	-- to correct for ip3 not being able to flow out at both dendritic ends
function ourNeumannBndIP3(x, y, z, t, si)
	if 	(si>=synStart and si<=synStop and syns[si]+ip3EntryDelay<t and t<=syns[si]+ip3EntryDelay+ip3EntryDuration)
	then influx = math.exp(corrFact*t) * 2.1e-5/1.188 * (1.0 - (t-syns[si])/ip3EntryDuration)
	else influx = 0.0
	end
    
    return influx
end

-------------------------------
-- setup approximation space --
-------------------------------
-- create, load, refine and distribute domain
-- (the distribution method is only needed for parallel execution and prevents cutting the domain along a membrane)
print("create, refine and distribute domain")
neededSubsets = {}
distributionMethod = "metisReweigh"
weightingFct = InterSubsetPartitionWeighting()
weightingFct:set_default_weights(1,1)
weightingFct:set_inter_subset_weight(0, 1, 1000)
dom = util.CreateAndDistributeDomain(gridName, numRefs, 0, neededSubsets, distributionMethod, nil, nil, nil, weightingFct)

--[[
--print("Saving domain grid and hierarchy.")
--SaveDomain(dom, "refined_grid_p" .. ProcRank() .. ".ugx")
--SaveGridHierarchyTransformed(dom:grid(), "refined_grid_hierarchy_p" .. ProcRank() .. ".ugx", 2.0)
print("Saving parallel grid layout")
SaveParallelGridLayout(dom:grid(), "parallel_grid_layout_p"..ProcRank()..".ugx", 2.0)
--]]

-- create approximation space
print("Create ApproximationSpace")
approxSpace = ApproximationSpace(dom)

-- collect several subset names in subdomain variables
cytVol = "cyt"
measZones = "head, neck, dend"
cytVol = cytVol .. ", " .. measZones

erVol = "er, app"

plMem = "mem_cyt, syn"

erMem = "mem_er, mem_app"
measZonesERM = "measZoneERM"..1
for i=2,3 do
	measZonesERM = measZonesERM .. ", measZoneERM" .. i
end
erMem = erMem .. ", " .. measZonesERM

outerDomain = cytVol .. ", " .. plMem .. ", " .. erMem
innerDomain = erVol .. ", " .. erMem

-- declare the unknown functions in the approximation space
approxSpace:add_fct("ca_er", "Lagrange", 1, innerDomain)
approxSpace:add_fct("ca_cyt", "Lagrange", 1, outerDomain)
approxSpace:add_fct("ip3", "Lagrange", 1, outerDomain)
approxSpace:add_fct("clb", "Lagrange", 1, outerDomain)

-- initialize approximation space and output some information
approxSpace:init_levels()
approxSpace:print_layout_statistic()
approxSpace:print_statistic()

----------------------------------------------------------
-- setup FV convection-diffusion element discretization --
----------------------------------------------------------
print ("Setting up Assembling")

if dim == 2 then 
    upwind = NoUpwind2d()
elseif dim == 3 then 
    upwind = NoUpwind3d()
end

elemDiscER = ConvectionDiffusion("ca_er", erVol, "fv1") 
elemDiscER:set_diffusion(D_cae)
elemDiscER:set_upwind(upwind)

elemDiscCYT = ConvectionDiffusion("ca_cyt", cytVol, "fv1")
elemDiscCYT:set_diffusion(D_cac)
elemDiscCYT:set_upwind(upwind)

elemDiscIP3 = ConvectionDiffusion("ip3", cytVol, "fv1")
elemDiscIP3:set_diffusion(D_ip3)
elemDiscIP3:set_reaction_rate(reactionRateIP3)
elemDiscIP3:set_reaction(reactionTermIP3)
elemDiscIP3:set_upwind(upwind)

elemDiscClb = ConvectionDiffusion("clb", cytVol, "fv1")
elemDiscClb:set_diffusion(D_clb)
elemDiscClb:set_upwind(upwind)

---------------------------------------
-- setup reaction terms of buffering --
---------------------------------------
elemDiscBuffering = BufferFV1(cytVol)	-- where buffering occurs
elemDiscBuffering:add_reaction(
	"clb",						    -- the buffering substance
	"ca_cyt",						-- the buffered substance
	totalClb,						-- total amount of buffer
	k_bind_clb,					    -- binding rate constant
	k_unbind_clb)				    -- unbinding rate constant

----------------------------------------------------
-- setup inner boundary (channels on ER membrane) --
----------------------------------------------------
-- The order, in which the discrete fcts are passed, is crucial!
innerDiscIP3R = TwoSidedIP3RFV1("ca_cyt, ca_er, ip3", erMem)
innerDiscIP3R:set_density_function("IP3Rdensity")
innerDiscRyR = TwoSidedRyRFV1("ca_cyt, ca_er", erMem)
innerDiscRyR:set_density_function("RYRdensity")
innerDiscSERCA = TwoSidedSERCAFV1("ca_cyt, ca_er", erMem)
innerDiscSERCA:set_density_function("SERCAdensity")
innerDiscLeak = TwoSidedERCalciumLeakFV1("ca_cyt, ca_er", erMem)
innerDiscLeak:set_density_function("LEAKERconstant")

------------------------------
-- setup Neumann boundaries --
------------------------------
-- synaptic activity
neumannDiscCA = UserFluxBoundaryFV1("ca_cyt", plMem)
neumannDiscCA:set_flux_function("ourNeumannBndCA")
neumannDiscIP3 = UserFluxBoundaryFV1("ip3", plMem)
neumannDiscIP3:set_flux_function("ourNeumannBndIP3")


-- plasme membrane transport systems
neumannDiscPMCA = OneSidedPMCAFV1("ca_cyt", plMem)
neumannDiscPMCA:set_density_function("PMCAdensity")
neumannDiscNCX = OneSidedNCXFV1("ca_cyt", plMem)
neumannDiscNCX:set_density_function("NCXdensity")
neumannDiscLeak = OneSidedPMCalciumLeakFV1("ca_cyt", plMem)
neumannDiscLeak:set_density_function("LEAKPMconstant")

-- VGCCs: you have to provide a path to files containing the voltage values on the membrane for each time step
-- if you do not have any, you ccan comment this out (for the time being)
--[[
neumannDiscVGCC = OneSidedBorgGrahamFV1WithVM2UG("ca_cyt", plMem, approxSpace,
		"neuronRes/timestep".."_order".. 0 .."_jump"..string.format("%1.1f", 5.0).."_", "%.3f", ".dat", false)
neumannDiscVGCC:set_channel_type_L() --default, but to be sure
neumannDiscVGCC:set_density_function("VGCCdensity")
neumannDiscVGCC:init(0.0)
voltageFilesInterval = 0.001;
--]]

------------------------------------------
-- setup complete domain discretization --
------------------------------------------

-- The domain disc collects all element discs setup before.
-- Here, you can comfortably switch on and off specific mechanisms by commenting them out.
domainDisc = DomainDiscretization(approxSpace)

-- diffusion discretizations
domainDisc:add(elemDiscER)
domainDisc:add(elemDiscCYT)
domainDisc:add(elemDiscIP3)
domainDisc:add(elemDiscClb)

-- buffering disc
domainDisc:add(elemDiscBuffering)

-- (outer) boundary conditions
domainDisc:add(neumannDiscCA)
domainDisc:add(neumannDiscIP3)

domainDisc:add(neumannDiscPMCA)
domainDisc:add(neumannDiscNCX)
domainDisc:add(neumannDiscLeak)
--domainDisc:add(neumannDiscVGCC)

-- ER flux
domainDisc:add(innerDiscIP3R)
domainDisc:add(innerDiscRyR)
domainDisc:add(innerDiscSERCA)
domainDisc:add(innerDiscLeak)

-------------------------------
-- setup time discretization --
-------------------------------
timeDisc = ThetaTimeStep(domainDisc)
timeDisc:set_theta(1.0) -- 1.0 is implicit Euler

-- create operator from discretization
op = AssembledOperator()
op:set_discretization(timeDisc)
op:init()

------------------
-- solver setup --
------------------
-- create algebraic preconditioner
jac = Jacobi()
jac:set_damp(0.8)
gs = GaussSeidel()
sgs = SymmetricGaussSeidel()
bgs = BackwardGaussSeidel()
ilu = ILU()
ilut = ILUT()

-- exact solver
exactSolver = LU()


-- geometric multi-grid --
-- base solver
baseConvCheck = ConvCheck()
baseConvCheck:set_maximum_steps(1000)
baseConvCheck:set_minimum_defect(1e-28)
baseConvCheck:set_reduction(1e-1)
baseConvCheck:set_verbose(false)

-- debug writer
dbgWriter = GridFunctionDebugWriter(approxSpace)
dbgWriter:set_vtk_output(false)

if (solverID == "GMG-LU") then
    base = exactSolver
else
    base = LinearSolver()
    base:set_convergence_check(baseConvCheck)
    if (solverID == "GMG-ILU") then
        base:set_preconditioner(ilu)
    else
        base:set_preconditioner(gs)
    end
end

-- gmg
gmg = GeometricMultiGrid(approxSpace)
gmg:set_discretization(timeDisc)
gmg:set_base_level(0)
if (solverID == "GMG-LU") then
    gmg:set_gathered_base_solver_if_ambiguous(true)
end
gmg:set_base_solver(base)
if (solverID == "GMG-ILU") then
    gmg:set_smoother(ilu)
else
    gmg:set_smoother(ilu)
end 
gmg:set_cycle_type(1)
gmg:set_num_presmooth(5)
gmg:set_num_postsmooth(3)
--gmg:set_debug(dbgWriter)

-- biCGstab --
convCheck = ConvCheck()
convCheck:set_minimum_defect(1e-24)
convCheck:set_reduction(1e-06)
convCheck:set_verbose(false)	-- set true if you wish to get output from the linear solver
bicgstabSolver = BiCGStab()
if (solverID == "ILU") then
    convCheck:set_maximum_steps(2000)
    bicgstabSolver:set_preconditioner(ilu)
elseif (solverID == "GS") then
    convCheck:set_maximum_steps(2000)
    bicgstabSolver:set_preconditioner(gs)
elseif (solverID == "JAC") then
    convCheck:set_maximum_steps(2000)
    bicgstabSolver:set_preconditioner(jac)
else
    convCheck:set_maximum_steps(100)
    bicgstabSolver:set_preconditioner(gmg)
end
bicgstabSolver:set_convergence_check(convCheck)

-----------------------
-- non linear solver --
-----------------------
-- convergence check
newtonConvCheck = CompositeConvCheck3dCPU1(approxSpace, 10, 1e-28, 1e-08)
newtonConvCheck:set_verbose(true)
newtonConvCheck:set_time_measurement(true)

newtonLineSearch = StandardLineSearch()
newtonLineSearch:set_maximum_steps(5)
newtonLineSearch:set_accept_best(true)
newtonLineSearch:set_verbose(false)

-- Newton solver
newtonSolver = NewtonSolver()
newtonSolver:set_linear_solver(bicgstabSolver)
newtonSolver:set_convergence_check(newtonConvCheck)
--newtonSolver:set_line_search(newtonLineSearch)

newtonSolver:init(op)



-------------
-- solving --
-------------

-- get a grid function
u = GridFunction(approxSpace)

-- set initial values
Interpolate(ca_cyt_init, u, "ca_cyt", 0.0)
Interpolate(ca_er_init, u, "ca_er", 0.0)
Interpolate(ip3_init, u, "ip3", 0.0)
Interpolate(clb_init, u, "clb", 0.0)


-- timestep in seconds
dt = timeStepStart
time = 0.0
step = 0

if (generateVTKoutput) then
	out = VTKOutput()
	out:print(fileName .. "vtk/result", u, step, time)
end


-- taking an initial measurement of all unknwons in all measurement zones on the ER membrane
-- the folder "meas" must exist in your file output directory specified in fileName
takeMeasurement(u, time, measZonesERM, "ca_cyt, ca_er, ip3, clb", fileName .. "meas/data")


-- create new grid function for old value
uOld = u:clone()

-- store grid function in vector of  old solutions
solTimeSeries = SolutionTimeSeries()
solTimeSeries:push(uOld, time)

-- compute volumes of certain subdomains and print to command line
--computeVolume(approxSpace, "head, neck, app, syn, mem_er")

-- prepare adaptive time stepping
min_dt = timeStep / math.pow(2,15)
cb_interval = 10
lv = startLv
levelUpDelay = caEntryDuration + (nSpikes - 1) * 1.0/freq;
cb_counter = {}
for i=0,startLv do cb_counter[i]=0 end

-- start time loop
while endTime-time > 0.001*dt do
	print("++++++ POINT IN TIME  " .. math.floor((time+dt)/dt+0.5)*dt .. "s  BEGIN ++++++")
	
	-- setup time disc for old solutions and timestep
	timeDisc:prepare_step(solTimeSeries, dt)
	
	-- prepare newton solver
	if newtonSolver:prepare(u) == false then print ("Newton solver failed at step "..step.."."); exit(); end 
	
	-- prepare VDCC channel state
	--[[ never update, so that always -72mV
	if (time+dt<0.2) then
		vm_time = math.floor((time+dt)/voltageFilesInterval)*voltageFilesInterval	-- truncate to last time that data exists for
		neumannDiscVGCC:update_potential(vm_time)
	end
	neumannDiscVGCC:update_gating(time+dt)
	--]]
	
	-- apply newton solver
	if newtonSolver:apply(u) == false
	then
		-- in case of failure:
		print ("Newton solver failed at point in time " .. time .. " with time step " .. dt)
		
		-- correction for Borg-Graham channels: have to set back time
		--neumannDiscVGCC:update_gating(time)
		
		dt = dt/2
		lv = lv + 1
		VecScaleAssign(u, 1.0, solTimeSeries:latest())
		
		-- halve time step and try again unless time step below minimum
		if dt < min_dt
		then 
			print ("Time step below minimum. Aborting. Failed at point in time " .. time .. ".")
			time = endTime
		else
			print ("Trying with half the time step...")
			cb_counter[lv] = 0
		end
	else
		-- update new time
		time = solTimeSeries:time(0) + dt
		
		-- every once in a while check if we can increase the time step
		-- update check-back counter and if applicable, reset dt
		cb_counter[lv] = cb_counter[lv] + 1
		while cb_counter[lv] % (2*cb_interval) == 0 and lv > 0 and (time >= levelUpDelay or lv > startLv) do
			print ("Doubling time due to continuing convergence; now: " .. 2*dt)
			dt = 2*dt;
			lv = lv - 1
			cb_counter[lv] = cb_counter[lv] + cb_counter[lv+1] / 2
			cb_counter[lv+1] = 0
		end
		
		-- plot solution every plotStep seconds
		if (generateVTKoutput) then
			if math.abs(time/plotStep - math.floor(time/plotStep+0.5)) < 1e-5 then
				out:print(fileName .. "vtk/result", u, math.floor(time/plotStep+0.5), time)
			end
		end
		
		-- take measurements in measurement zones
		takeMeasurement(u, time, measZonesERM, "ca_cyt, ca_er, ip3, clb", fileName .. "meas/data")
				
		-- get oldest solution
		oldestSol = solTimeSeries:oldest()
		-- copy values into oldest solution (we reuse the memory here)
		VecScaleAssign(oldestSol, 1.0, u)
		-- push oldest solutions with new values to front, oldest sol pointer is popped from end
		solTimeSeries:push_discard_oldest(oldestSol, time)
		
		print("++++++ POINT IN TIME  " .. math.floor(time/dt+0.5)*dt .. "s  END ++++++++");
	end
end

-- end timeseries, produce gathering paraview file
if (generateVTKoutput) then out:write_time_pvd(fileName .. "vtk/result", u) end