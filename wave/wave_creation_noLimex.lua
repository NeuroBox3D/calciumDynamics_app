--------------------------------------------------------------------------------
-- Examination of calcium wave prerequisites                                  --
--                                                                            --
-- This script is intended to be used for simulations on 2d representations   --
-- of perfectly rotationally symmetric model dendrites.                       --
-- The goal of the simulations is to find out rules for whether or not a      --
-- calcium wave is elicited upon synaptic activation.                         --
-- An implicit theta time step method is used for time stepping and a Newton  --
-- iteration for the treatment of nonlinearities.                             --
--                                                                            --
-- Author: Markus Breit                                                       --
-- Date:   2017-08-08                                                         --
--------------------------------------------------------------------------------

-- for profiler output
--SetOutputProfileStats(true)

-- load pre-implemented lua functions
ug_load_script("ug_util.lua")
ug_load_script("util/load_balancing_util.lua")

AssertPluginsLoaded({"neuro_collection", "Parmetis"})

EnableLUA2C(true)  -- speed up evaluation of lua functions by c program
--SetDebugLevel(debugID.LUACompiler, 0) 


-------------------------------------
-- parse command line parameters  ---
-------------------------------------

-- choice of grid name
gridName = util.GetParam("-grid", "modelDendrite.ugx")

-- grid parameters
dendLength = util.GetParamNumber("-dendLength", 50.0)
dendRadius = util.GetParamNumber("-dendRadius", 0.5)
erRadius = util.GetParamNumber("-erRadius", 0.158)
synArea = util.GetParamNumber("-synArea", math.pi*0.5)
nSeg = util.GetParamNumber("-nSeg", 100)

-- refinements (global and at ERM)
numGlobRefs = util.GetParamNumber("-numGlobRefs", 0)
numERMRefs = util.GetParamNumber("-numERMRefs", 0)

-- which ER mechanisms are to be activated?
setting = util.GetParam("-setting", "all")
setting = string.lower(setting)
validSettings = {}
validSettings["all"] = 0;
validSettings["none"] = 0;
validSettings["ip3r"] = 0;
validSettings["ryr"] = 0;
if (validSettings[setting] == nil) then
    error("Unknown setting " .. setting)
end

-- choice of algebra
useBlockAlgebra = util.HasParamOption("-block")

-- choice of solver setup
solverID = util.GetParam("-solver", "GMG")
solverID = string.upper(solverID)
validSolverIDs = {}
validSolverIDs["GMG"] = 0
validSolverIDs["GS"] = 0
validSolverIDs["ILU"] = 0
if (validSolverIDs[solverID] == nil) then
    error("Unknown solver identifier " .. solverID)
end

-- specify "-verbose" to output linear solver convergence
verbose = util.HasParamOption("-verbose")

-- parameters for instationary simulation
dt = util.GetParamNumber("-dt", 1e-2)
dtStart = util.GetParamNumber("-dtStart", dt)
endTime = util.GetParamNumber("-endTime", 1.0)

-- choose outfile directory
outDir = util.GetParam("-outName", "caWaveExploration")
outDir = outDir .. "/"

-- specify -vtk to generate vtk output
generateVTKoutput = util.HasParamOption("-vtk")
pstep = util.GetParamNumber("-pstep", dt, "plotting interval")



-- init with dimension and algebra
if useBlockAlgebra then
	InitUG(2, AlgebraType("CPU", 4))
else
	InitUG(2, AlgebraType("CPU", 1))
end

-----------------------
-- geometry creation --
-----------------------

if ProcRank() == 0 then
	gen = DendriteGenerator()
	gen:set_dendrite_length(dendLength)
	gen:set_dendrite_radius(dendRadius)
	gen:set_er_radius(erRadius)
	gen:set_synapse_area(synArea)
	gen:set_num_segments(nSeg)
	
	gridName = outDir .. "grid/" .. gridName
	gen:create_dendrite(gridName)
end

PclDebugBarrierAll()


-------------------------
--  problem constants  --
-------------------------
-- setting-dependent variables
withIP3R = true
withRyR = true
withSERCAandLeak = true

if setting == "none" then 
	withIP3R = false
	withRyR = false
	withSERCAandLeak = false
end

if setting == "ip3r" then
	withRyR = false
end

if setting == "ryr" then
	withIP3R = false
end


-- total cytosolic calbindin concentration
-- (four times the real value in order to simulate four binding sites in one)
totalClb = 4*40.0e-6

-- diffusion coefficients
D_cac = 220.0
D_cae = 220.0
D_ip3 = 280.0
D_clb = 20.0

-- calbindin binding rates
k_bind_clb = 27.0e06
k_unbind_clb = 19

-- initial concentrations
ca_cyt_init = 5.0e-08
ca_er_init = 2.5e-4
ip3_init = 4.0e-8
clb_init = totalClb / (k_bind_clb/k_unbind_clb*ca_cyt_init + 1)


-- IP3 constants
reactionRateIP3 = 0.11
equilibriumIP3 = 4.0e-08
reactionTermIP3 = -reactionRateIP3 * equilibriumIP3

-- ER densities
IP3Rdensity = 17.3
RYRdensity = 0.86
leakERconstant = 3.8e-17
local v_s = 6.5e-27  -- V_S param of SERCA pump
local k_s = 1.8e-7   -- K_S param of SERCA pump
local j_ip3r = 3.7606194166520605e-23   -- single channel IP3R flux (mol/s) - to be determined via gdb
local j_ryr = 1.1201015633466695e-21    -- single channel RyR flux (mol/s) - to be determined via gdb
				  						-- ryr1: 1.1204582669024472e-21	
local j_leak = ca_er_init-ca_cyt_init	-- leak proportionality factor


SERCAfluxDensity = leakERconstant * j_leak
if withIP3R then 
	SERCAfluxDensity = SERCAfluxDensity + IP3Rdensity * j_ip3r
end
if withRyR then
	SERCAfluxDensity = SERCAfluxDensity + RYRdensity * j_ryr
end
SERCAdensity = SERCAfluxDensity / (v_s/(k_s/ca_cyt_init+1.0)/ca_er_init)
if (SERCAdensity < 0) then error("SERCA flux density is outward for these density settings!") end

-- PM densities
pmcaDensity = 500.0
ncxDensity  = 15.0
vdccDensity = 0.0  -- 1.0
leakPMconstant =  pmcaDensity * 6.9672131147540994e-24	-- single pump PMCA flux (mol/s)
				+ ncxDensity *  6.7567567567567566e-23	-- single pump NCX flux (mol/s)
				--+ vdccDensity * (-1.5752042094823713e-25)    -- single channel VGCC flux (mol/s)
				-- *1.5 // * 0.5 for L-type // T-type
if (leakPMconstant < 0) then error("PM leak flux is outward for these density settings!") end


-- firing pattern of the synapse
synSubset = 4
caEntryDuration = 0.001
function synCurrentDensityCa(z, r, t, si)	
	-- single spike (~1200 ions)
	local influx
	if (si == synSubset and t <= caEntryDuration)
	then influx = 2.5e-3 * (1.0 - t/caEntryDuration)
	else influx = 0.0
	end
	
    return math.pi*influx -- scale with constant radius 0.5 to keep influx constant on all geometries
end

ip3EntryDelay = 0.000
ip3EntryDuration = 0.2
function synCurrentDensityIP3(z, r, t, si)
	local influx
	if (si == synSubset and t > ip3EntryDelay and t <= ip3EntryDelay+ip3EntryDuration)
	then influx = 7.5e-5 * (1.0 - t/ip3EntryDuration)
	else influx = 0.0
	end
	
    return math.pi*influx -- scale with constant radius 0.5 to keep influx constant on all geometries
end

-------------------------------
-- setup approximation space --
-------------------------------

-- load domain
reqSubsets = {"cyt", "er", "pm", "erm", "act", "meas"}
dom = util.CreateDomain(gridName, 0, reqSubsets)

-- create approximation space
approxSpace = ApproximationSpace(dom)

cytVol = "cyt"
erVol = "er"
plMem = "pm"
plMem_vec = {"pm"}
erMem = "erm"
erMemVec = {"erm"}

outerDomain = cytVol .. ", " .. plMem .. ", " .. erMem .. ", act, meas"
innerDomain = erVol .. ", " .. erMem

if useBlockAlgebra then
	approxSpace:add_fct("ca_cyt", "Lagrange", 1)
	approxSpace:add_fct("ca_er", "Lagrange", 1)
	approxSpace:add_fct("clb", "Lagrange", 1)
	approxSpace:add_fct("ip3", "Lagrange", 1)
	approxSpace:add_fct("o2", "Lagrange", 1)
	approxSpace:add_fct("c1", "Lagrange", 1)
	approxSpace:add_fct("c2", "Lagrange", 1)
else
	approxSpace:add_fct("ca_cyt", "Lagrange", 1, outerDomain)
	approxSpace:add_fct("ca_er", "Lagrange", 1, innerDomain)
	approxSpace:add_fct("clb", "Lagrange", 1, outerDomain)
	approxSpace:add_fct("ip3", "Lagrange", 1, outerDomain)
	approxSpace:add_fct("o2", "Lagrange", 1, erMem)
	approxSpace:add_fct("c1", "Lagrange", 1, erMem)
	approxSpace:add_fct("c2", "Lagrange", 1, erMem)
end
approxSpace:init_levels()
approxSpace:init_surfaces()
approxSpace:init_top_surface()
approxSpace:print_layout_statistic()
approxSpace:print_statistic()

if useBlockAlgebra then
	OrderCuthillMcKee(approxSpace, true)
end


-- ERM refinements
refiner = HangingNodeDomainRefiner(dom)

for i = 1, numERMRefs do
	MarkAlongSurface(refiner, dom, {"erm"}, {"cyt"})
	refiner:refine()
end

-- global refinements
for i = 1, numGlobRefs do
	MarkGlobal(refiner, dom)
	refiner:refine()
end


-- in parallel environments: domain distribution
balancer.partitioner = "parmetis"
balancer.staticProcHierarchy = true
balancer.firstDistLvl = -1
balancer.redistSteps = 0
balancer.parallelElementThreshold = 8

balancer.ParseParameters()
balancer.PrintParameters()

loadBalancer = balancer.CreateLoadBalancer(dom)
if loadBalancer ~= nil then
	loadBalancer:enable_vertical_interface_creation(solverID == "GMG")
	if balancer.partitioner == "parmetis" then
		mu = ManifoldUnificator(dom)
		mu:add_protectable_subsets("erm")
		cdgm = ClusteredDualGraphManager()
		cdgm:add_unificator(SiblingUnificator())
		cdgm:add_unificator(mu)
		balancer.defaultPartitioner:set_dual_graph_manager(cdgm)
	end
	balancer.Rebalance(dom, loadBalancer)
	loadBalancer:estimate_distribution_quality()
	loadBalancer:print_quality_records()
	if balancer.partitioner == "parmetis" then
		print("Edge cut on base level: "..balancer.defaultPartitioner:edge_cut_on_lvl(0))
	end
end

print(dom:domain_info():to_string())
SaveGridHierarchyTransformed(dom:grid(), dom:subset_handler(), outDir .. "grid/refined_grid_hierarchy_p" .. ProcRank() .. ".ugx", 1.0)
--SaveParallelGridLayout(dom:grid(), outDir .. "grid/parallel_grid_layout_p"..ProcRank()..".ugx", 1.0)


--------------------------
-- setup discretization --
--------------------------
-- scaled coefficient functions
function scaled_diff_cac(z,r,t)
	local c = 2*math.pi*r*D_cac
	return  c, 0,
			0, c
end
function scaled_diff_cae(z,r,t)
	local c = 2*math.pi*r*D_cae
	return  c, 0,
			0, c
end
function scaled_diff_clb(z,r,t)
	local c = 2*math.pi*r*D_clb
	return  c, 0,
			0, c
end
function scaled_diff_ip3(z,r,t)
	local c = 2*math.pi*r*D_ip3
	return  c, 0,
			0, c
end
function scaled_reactionRate_ip3(z,r,t)
	return 2*math.pi*r*reactionRateIP3
end
function scaled_reactionTerm_ip3(z,r,t)
	return 2*math.pi*r*reactionTermIP3
end
function buffer_kBind(z,r,t)
	return 2*math.pi*r*k_bind_clb
end
function buffer_kUnbind(z,r,t)
	return 2*math.pi*r*k_unbind_clb
end
function rotSym_scale(z,r,t)
	return 2*math.pi*r
end


-- diffusion --
diffCaCyt = ConvectionDiffusion("ca_cyt", cytVol, "fv1")
diffCaCyt:set_mass_scale("rotSym_scale")
diffCaCyt:set_diffusion("scaled_diff_cac")

diffCaER = ConvectionDiffusion("ca_er", erVol, "fv1")
diffCaER:set_mass_scale("rotSym_scale")
diffCaER:set_diffusion("scaled_diff_cae")

diffClb = ConvectionDiffusion("clb", cytVol, "fv1")
diffClb:set_mass_scale("rotSym_scale")
diffClb:set_diffusion("scaled_diff_clb")

diffIP3 = ConvectionDiffusion("ip3", cytVol, "fv1")
diffIP3:set_mass_scale("rotSym_scale")
diffIP3:set_diffusion("scaled_diff_ip3")
diffIP3:set_reaction_rate("scaled_reactionRate_ip3")
diffIP3:set_reaction("scaled_reactionTerm_ip3")


-- buffering --
discBuffer = BufferFV1(cytVol) -- where buffering occurs
discBuffer:add_reaction(
	"clb",                     -- the buffering substance
	"ca_cyt",                  -- the buffered substance
	totalClb,                  -- total amount of buffer
	"buffer_kBind",            -- binding rate constant
	"buffer_kUnbind"           -- unbinding rate constant
)


-- er membrane transport systems
ip3r = IP3R({"ca_cyt", "ca_er", "ip3"})
ip3r:set_scale_inputs({1e3,1e3,1e3})
ip3r:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)

--[[
--ryr = RyR({"ca_cyt", "ca_er"})
ryr = RyRinstat({"ca_cyt", "ca_er"}, erMemVec, approxSpace)
ryr:set_scale_inputs({1e3,1e3})
ryr:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)
--]]
ryr = RyRImplicit({"ca_cyt", "ca_er", "o2", "c1", "c2"}, erMemVec)
ryr:set_scale_inputs({1e3, 1e3, 1.0, 1.0, 1.0})
ryr:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)

serca = SERCA({"ca_cyt", "ca_er"})
serca:set_scale_inputs({1e3,1e3})
serca:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)

leakER = Leak({"ca_er", "ca_cyt"})
leakER:set_scale_inputs({1e3,1e3})
leakER:set_scale_fluxes({1e3}) -- from mol/(m^2 s) to (mol um)/(dm^3 s)


discIP3R = MembraneTransportFV1(erMem, ip3r)
discIP3R:set_density_function(IP3Rdensity)
discIP3R:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d

discRyR = MembraneTransportFV1(erMem, ryr)
discRyR:set_density_function(RYRdensity)
discRyR:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d

discSERCA = MembraneTransportFV1(erMem, serca)
discSERCA:set_density_function(SERCAdensity)
discSERCA:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d

discERLeak = MembraneTransportFV1(erMem, leakER)
discERLeak:set_density_function(1e12*leakERconstant/(1e3)) -- from mol/(um^2 s M) to m/s
discERLeak:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d

-- plasma membrane transport systems
pmca = PMCA({"ca_cyt", ""})
pmca:set_constant(1, 1.0)
pmca:set_scale_inputs({1e3,1.0})
pmca:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)

ncx = NCX({"ca_cyt", ""})
ncx:set_constant(1, 1.0)
ncx:set_scale_inputs({1e3,1.0})
ncx:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)

leakPM = Leak({"", "ca_cyt"})
leakPM:set_constant(0, 1.0)
leakPM:set_scale_inputs({1.0,1e3})
leakPM:set_scale_fluxes({1e3}) -- from mol/(m^2 s) to (mol um)/(dm^3 s)

--[[
vdcc = VDCC_BG_CN({"ca_cyt", ""}, plMem_vec, approxSpace1d, approxSpace, "v")
vdcc:set_domain_disc_1d(domDisc1d)
vdcc:set_cable_disc(CE)
vdcc:set_coordinate_scale_factor_3d_to_1d(1e-6)
if withIons then
	vdcc:set_initial_values({v_eq, k_in, na_in, ca_in})
else
	vdcc:set_initial_values({v_eq})
end
vdcc:set_time_steps_for_simulation_and_potential_update(dt1d, dt1d)
vdcc:set_solver_output_verbose(verbose1d)
if generateVTKoutput then
	vdcc:set_vtk_output(outDir.."vtk/solution1d", pstep)
end
vdcc:set_constant(1, 1.5)
vdcc:set_scale_inputs({1e3,1.0})
vdcc:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)
vdcc:set_channel_type_L() --default, but to be sure
vdcc:init(0.0)
--]]

discPMCA = MembraneTransportFV1(plMem, pmca)
discPMCA:set_density_function(pmcaDensity)
discPMCA:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d

discNCX = MembraneTransportFV1(plMem, ncx)
discNCX:set_density_function(ncxDensity)
discNCX:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d

discPMLeak = MembraneTransportFV1(plMem, leakPM)
discPMLeak:set_density_function(1e12*leakPMconstant / (1.0-1e3*ca_cyt_init))
discPMLeak:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d

--[[
discVDCC = MembraneTransportFV1(plMem, vdcc)
discVDCC:set_density_function(vdccDensity)
discVDCC:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d
--]]

-- synaptic activity
synapseInfluxCa = UserFluxBoundaryFV1("ca_cyt", "act")
synapseInfluxCa:set_flux_function("synCurrentDensityCa")
synapseInfluxIP3 = UserFluxBoundaryFV1("ip3", "act")
synapseInfluxIP3:set_flux_function("synCurrentDensityIP3")


-- domain discretization --
domDisc = DomainDiscretization(approxSpace)

domDisc:add(diffCaCyt)
domDisc:add(diffCaER)
domDisc:add(diffClb)
domDisc:add(diffIP3)

domDisc:add(discBuffer)

if withIP3R then
	domDisc:add(discIP3R)
end
if withRyR then
	domDisc:add(discRyR)
	domDisc:add(ryr) -- also add ryr as elem disc (for state variables)
end
if withSERCAandLeak then
	domDisc:add(discSERCA)
	domDisc:add(discERLeak)
end

domDisc:add(discPMCA)
domDisc:add(discNCX)
domDisc:add(discPMLeak)
--domDisc:add(discVDCC)

domDisc:add(synapseInfluxCa)
if withIP3R then
	domDisc:add(synapseInfluxIP3)
end

-- Dirichlet for superfluous dofs
if useBlockAlgebra then
	uselessDofDiri = DirichletBoundary()
	uselessDofDiri:add(ca_cyt_init, "ca_cyt", "er, bnd_er")
	uselessDofDiri:add(ip3_init, "ip3", "er, bnd_er")
	uselessDofDiri:add(clb_init, "clb", "er, bnd_er")
	uselessDofDiri:add(ca_er_init, "ca_er", "cyt, pm, syn, bnd_cyt")

	domDisc:add(uselessDofDiri)
end

-- constraints for adaptivity
if numERMRefs > 0 then
	hangingConstraint = SymP1Constraints()--OneSideP1Constraints()
	domDisc:add(hangingConstraint)
end

-- setup time discretization --
timeDisc = ThetaTimeStep(domDisc)
timeDisc:set_theta(0.5) -- 1.0 is implicit Euler; 0.5 Crank-Nicolson
-- TODO: Think about implicit shift: 0.5 + c*dt

-- create operator from discretization
op = AssembledOperator()
op:set_discretization(timeDisc)
op:init()


------------------
-- solver setup --
------------------
-- debug writer
dbgWriter = GridFunctionDebugWriter(approxSpace)
dbgWriter:set_base_dir(outDir)
dbgWriter:set_vtk_output(false)

-- biCGstab --
convCheck = ConvCheck()
convCheck:set_minimum_defect(1e-50)
convCheck:set_reduction(1e-8)
convCheck:set_verbose(verbose)

if (solverID == "ILU") then
    bcgs_steps = 1000
    ilu = ILU()
    ilu:set_sort(true)
    bcgs_precond = ilu
elseif (solverID == "GS") then
    bcgs_steps = 1000
    bcgs_precond = GaussSeidel()
else -- (solverID == "GMG")
	gmg = GeometricMultiGrid(approxSpace)
	gmg:set_discretization(timeDisc)
	gmg:set_base_level(0)
	gmg:set_gathered_base_solver_if_ambiguous(true)
	
	-- treat SuperLU problems with Dirichlet constraints by using constrained version
	gmg:set_base_solver(SuperLU())
	
	smoother = GaussSeidel()
	gmg:set_smoother(smoother)
	gmg:set_smooth_on_surface_rim(true)
	gmg:set_cycle_type(1)
	gmg:set_num_presmooth(3)
	gmg:set_num_postsmooth(3)
	--gmg:set_rap(true)
	--gmg:set_debug(GridFunctionDebugWriter(approxSpace))
	
    bcgs_steps = 100
	bcgs_precond = gmg
end

convCheck:set_maximum_steps(bcgs_steps)

bicgstabSolver = BiCGStab()
bicgstabSolver:set_preconditioner(bcgs_precond)
bicgstabSolver:set_convergence_check(convCheck)
--bicgstabSolver:set_debug(dbgWriter)

--- non-linear solver ---
-- convergence check
newtonConvCheck = CompositeConvCheck(approxSpace, 10, 1e-15, 1e-08)
--newtonConvCheck:set_component_check("ca_cyt, ca_er, clb, ip3", 1e-18, 1e-10)
newtonConvCheck:set_verbose(true)
newtonConvCheck:set_time_measurement(true)
newtonConvCheck:set_adaptive(true)

-- Newton solver
newtonSolver = NewtonSolver()
newtonSolver:set_linear_solver(bicgstabSolver)
newtonSolver:set_convergence_check(newtonConvCheck)
--newtonSolver:set_debug(dbgWriter)

newtonSolver:init(op)


-------------
-- solving --
-------------
-- get grid function
u = GridFunction(approxSpace)

-- set initial value
InterpolateInner(ca_cyt_init, u, "ca_cyt", 0.0)
InterpolateInner(ca_er_init, u, "ca_er", 0.0)
InterpolateInner(clb_init, u, "clb", 0.0)
InterpolateInner(ip3_init, u, "ip3", 0.0)
ryr:calculate_steady_state(u)

-- align start time step
function log2(x)
	return math.log(x)/math.log(2)
end
startLv = math.ceil(log2(dt/dtStart))
dtStartNew = dt / math.pow(2, startLv)
if (math.abs(dtStartNew-dtStart)/dtStart > 1e-5) then 
	print("dtStart argument ("..dtStart..") was not admissible;" ..
	       "taking "..dtStartNew.." instead.")
end
dt = dtStartNew

-- timestep in seconds
dtmin = 1e-9
dtmax = 1e-1
time = 0.0
step = 0

-- initial vtk output
if (generateVTKoutput) then
	out = VTKOutput()
	out:print(outDir .. "vtk/solution", u, step, time)
end


-- create new grid function for old value
uOld = u:clone()

-- store grid function in vector of  old solutions
solTimeSeries = SolutionTimeSeries()
solTimeSeries:push(uOld, time)


min_dt = dt / math.pow(2,15)
cb_interval = 10
lv = startLv
levelUpDelay = 0
cb_counter = {}
for i=0,startLv do cb_counter[i]=0 end
while endTime-time > 0.001*dt do
	print("++++++ POINT IN TIME  " .. math.floor((time+dt)/dt+0.5)*dt .. "s  BEGIN ++++++")
	
	-- setup time Disc for old solutions and timestep
	timeDisc:prepare_step(solTimeSeries, dt)
	
	-- apply newton solver
	if newtonSolver:apply(u) == false
	then
		-- in case of failure:
		print ("Newton solver failed at point in time " .. time .. " with time step " .. dt)

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
		
		-- update check-back counter and if applicable, reset dt
		cb_counter[lv] = cb_counter[lv] + 1
		while cb_counter[lv] % (2*cb_interval) == 0 and lv > 0 and (time >= levelUpDelay or lv > startLv) do
			print ("Doubling time due to continuing convergence; now: " .. 2*dt)
			dt = 2*dt;
			lv = lv - 1
			cb_counter[lv] = cb_counter[lv] + cb_counter[lv+1] / 2
			cb_counter[lv+1] = 0
		end
		
		-- plot solution every pstep seconds
		if (generateVTKoutput) then
			if math.abs(time/pstep - math.floor(time/pstep+0.5)) < 1e-5 then
				out:print(outDir .. "vtk/solution", u, math.floor(time/pstep+0.5), time)
			end
		end
		
		-- get oldest solution
		oldestSol = solTimeSeries:oldest()
		
		-- copy values into oldest solution (we reuse the memory here)
		VecScaleAssign(oldestSol, 1.0, u)
		
		-- push oldest solutions with new values to front, oldest sol pointer is popped from end
		solTimeSeries:push_discard_oldest(oldestSol, time)
		
		print("++++++ POINT IN TIME  " .. math.floor(time/dt+0.5)*dt .. "s  END ++++++++");
	end
end

-- end timeseries, produce gathering file
if (generateVTKoutput) then 
	out:write_time_pvd(outDir .. "vtk/solution", u)
end

if doProfiling then
	WriteProfileData(outDir .."pd.pdxml")
end
