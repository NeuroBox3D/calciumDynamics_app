------------------------------------------------------------------
-- Examination of calcium wave prerequisites                    --
--                                                              --
-- This script is intended to be used for simulations on 3d     --
-- model dendrites.                                             --
-- The goal of the simulations is to check that the 2d script   --
-- with rotation symmetry works alright.                        --
--                                                              --
-- Author: mbreit                                               --
-- Date:   2017-08-08                                           --
------------------------------------------------------------------

-- for profiler output
--SetOutputProfileStats(true)

-- load pre-implemented lua functions
ug_load_script("ug_util.lua")
ug_load_script("util/load_balancing_util.lua")
ug_load_script("plugins/Limex/limex_util.lua")

AssertPluginsLoaded({"neuro_collection", "Limex", "Parmetis"})

-- init with dimension and algebra
InitUG(3, AlgebraType("CPU", 1))

EnableLUA2C(true)  -- speed up evaluation of lua functions by c program
--SetDebugLevel(debugID.LUACompiler, 0) 


-------------------------------------
-- parse command line parameters  ---
-------------------------------------

-- choice of grid
gridName = util.GetParam("-grid", "../grids/modelDendrite3d.ugx")

-- refinements (global)
numRefs = util.GetParamNumber("-numRefs", 0)

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
endTime = util.GetParamNumber("-endTime", 1.0)

-- choose outfile directory
outDir = util.GetParam("-outName", "caWaveExploration")
outDir = outDir .. "/"

-- specify -vtk to generate vtk output
generateVTKoutput = util.HasParamOption("-vtk")
pstep = util.GetParamNumber("-pstep", dt, "plotting interval")


------------------------------------------------------
--  problem constants  -------------------------------
------------------------------------------------------
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
SERCAfluxDensity =   IP3Rdensity * 3.7606194166520605e-23      -- j_ip3r
			       + RYRdensity * 1.1204582669024472e-21       -- j_ryr
			       + leakERconstant * (ca_er_init-ca_cyt_init) -- j_leak
SERCAdensity = SERCAfluxDensity / (v_s/(k_s/ca_cyt_init+1.0)/ca_er_init)
if (SERCAdensity < 0) then error("SERCA flux density is outward for these density settings!") end

-- PM densities
pmcaDensity = 500.0
ncxDensity  = 15.0
vdccDensity = 0.0  -- 1.0
leakPMconstant =  pmcaDensity * 6.9672131147540994e-24	-- single pump PMCA flux (mol/s)
				+ ncxDensity *  6.7567567567567566e-23	-- single pump NCX flux (mol/s)
				+ vdccDensity * (-1.5752042094823713e-25)    -- single channel VGCC flux (mol/s)
				-- *1.5 // * 0.5 for L-type // T-type
if (leakPMconstant < 0) then error("PM leak flux is outward for these density settings!") end


-- firing pattern of the synapse
synSubset = 4
caEntryDuration = 0.001
function synCurrentDensityCa(x, y, z, t, si)	
	-- single spike (~1200 ions)
	local influx
	if (si == synSubset and t <= caEntryDuration)
	then influx = 2.5e-3 * (1.0 - t/caEntryDuration)
	else influx = 0.0
	end
	
    return influx
end

ip3EntryDelay = 0.000
ip3EntryDuration = 0.2
function synCurrentDensityIP3(x, y, z, t, si)
	local influx
	if (si == synSubset and t > ip3EntryDelay and t <= ip3EntryDelay+ip3EntryDuration)
	then influx = 7.5e-5 * (1.0 - t/ip3EntryDuration)
	else influx = 0.0
	end
	
    return influx
end

-------------------------------
-- setup approximation space --
-------------------------------

-- load domain
reqSubsets = {"cyt", "er", "pm", "erm", "syn", "bnd_cyt", "bnd_er"}
dom = util.CreateDomain(gridName, 0, reqSubsets)

-- in parallel environments: domain distribution
balancer.partitioner = "parmetis"
balancer.staticProcHierarchy = true
balancer.firstDistLvl = -1
balancer.redistSteps = 0

balancer.ParseParameters()
balancer.PrintParameters()

loadBalancer = balancer.CreateLoadBalancer(dom)
if loadBalancer ~= nil then
	loadBalancer:enable_vertical_interface_creation(solverID == "GMG")
	if balancer.partitioner == "parmetis" then
		ssp = SideSubsetProtector(dom:subset_handler())
		ssp:add_protectable_subset("erm")
		balancer.defaultPartitioner:set_dual_graph_manager(ssp)
	end
	balancer.Rebalance(dom, loadBalancer)
	loadBalancer:estimate_distribution_quality()
	loadBalancer:print_quality_records()
	if balancer.partitioner == "parmetis" then
		print("Edge cut on base level: "..balancer.defaultPartitioner:edge_cut_on_lvl(0))
	end
end

-- refinement
if numRefs > 0 then	
	local refiner = GlobalDomainRefiner(dom)	
	for i = 1, numRefs do
		refiner:refine()
	end
end

print(dom:domain_info():to_string())
SaveGridHierarchyTransformed(dom:grid(), dom:subset_handler(), outDir .. "grid/refined_grid_hierarchy_p" .. ProcRank() .. ".ugx", 1.0)
--SaveParallelGridLayout(dom:grid(), outDir .. "grid/parallel_grid_layout_p"..ProcRank()..".ugx", 1.0)


-- create approximation space
approxSpace = ApproximationSpace(dom)

cytVol = "cyt"
erVol = "er"
plMem = "pm, syn"
plMem_vec = {"pm, syn"}
erMem = "erm"
erMemVec = {"erm"}

outerDomain = cytVol .. ", " .. plMem .. ", " .. erMem .. ", bnd_cyt"
innerDomain = erVol .. ", " .. erMem .. ", bnd_er"

approxSpace:add_fct("ca_cyt", "Lagrange", 1, outerDomain)
approxSpace:add_fct("ca_er", "Lagrange", 1, innerDomain)
approxSpace:add_fct("clb", "Lagrange", 1, outerDomain)
approxSpace:add_fct("ip3", "Lagrange", 1, outerDomain)

approxSpace:init_levels()
approxSpace:init_surfaces()
approxSpace:init_top_surface()
approxSpace:print_layout_statistic()
approxSpace:print_statistic()

--OrderCuthillMcKee(approxSpace, true)


--------------------------
-- setup discretization --
--------------------------
-- diffusion --
diffCaCyt = ConvectionDiffusion("ca_cyt", cytVol, "fv1")
diffCaCyt:set_diffusion(D_cac)

diffCaER = ConvectionDiffusion("ca_er", erVol, "fv1")
diffCaER:set_diffusion(D_cae)

diffClb = ConvectionDiffusion("clb", cytVol, "fv1")
diffClb:set_diffusion(D_clb)

diffIP3 = ConvectionDiffusion("ip3", cytVol, "fv1")
diffIP3:set_diffusion(D_ip3)
diffIP3:set_reaction_rate(reactionRateIP3)
diffIP3:set_reaction(reactionTermIP3)


-- buffering --
discBuffer = BufferFV1(cytVol) -- where buffering occurs
discBuffer:add_reaction(
	"clb",                     -- the buffering substance
	"ca_cyt",                  -- the buffered substance
	totalClb,                  -- total amount of buffer
	k_bind_clb,                -- binding rate constant
	k_unbind_clb               -- unbinding rate constant
)


-- er membrane transport systems
ip3r = IP3R({"ca_cyt", "ca_er", "ip3"})
ip3r:set_scale_inputs({1e3,1e3,1e3})
ip3r:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)

--ryr = RyR({"ca_cyt", "ca_er"})
ryr = RyR2({"ca_cyt", "ca_er"}, erMemVec, approxSpace)
ryr:set_scale_inputs({1e3,1e3})
ryr:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)

serca = SERCA({"ca_cyt", "ca_er"})
serca:set_scale_inputs({1e3,1e3})
serca:set_scale_fluxes({1e15}) -- from mol/(um^2 s) to (mol um)/(dm^3 s)

leakER = Leak({"ca_er", "ca_cyt"})
leakER:set_scale_inputs({1e3,1e3})
leakER:set_scale_fluxes({1e3}) -- from mol/(m^2 s) to (mol um)/(dm^3 s)


discIP3R = MembraneTransportFV1(erMem, ip3r)
discIP3R:set_density_function(IP3Rdensity)

discRyR = MembraneTransportFV1(erMem, ryr)
discRyR:set_density_function(RYRdensity)

discSERCA = MembraneTransportFV1(erMem, serca)
discSERCA:set_density_function(SERCAdensity)

discERLeak = MembraneTransportFV1(erMem, leakER)
discERLeak:set_density_function(1e12*leakERconstant/(1e3)) -- from mol/(um^2 s M) to m/s

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

discNCX = MembraneTransportFV1(plMem, ncx)
discNCX:set_density_function(ncxDensity)

discPMLeak = MembraneTransportFV1(plMem, leakPM)
discPMLeak:set_density_function(1e12*leakPMconstant / (1.0-1e3*ca_cyt_init))

--[[
discVDCC = MembraneTransportFV1(plMem, vdcc)
discVDCC:set_density_function(vdccDensity)
discVDCC:set_flux_scale("rotSym_scale")  -- to achieve 3d rot. symm. simulation in 2d
--]]

-- synaptic activity
synapseInfluxCa = UserFluxBoundaryFV1("ca_cyt", "syn")
synapseInfluxCa:set_flux_function("synCurrentDensityCa")
synapseInfluxIP3 = UserFluxBoundaryFV1("ip3", "syn")
synapseInfluxIP3:set_flux_function("synCurrentDensityIP3")

--[[ -- only for blocked algebra
-- Dirichlet for superfluous dofs
uselessDofDiri = DirichletBoundary()
uselessDofDiri:add(ca_cyt_init, "ca_cyt", "er")
uselessDofDiri:add(ip3_init, "ip3", "er")
uselessDofDiri:add(clb_init, "clb", "er")
uselessDofDiri:add(ca_er_init, "ca_er", "cyt, pm")
--]]

-- domain discretization --
domDisc = DomainDiscretization(approxSpace)

domDisc:add(diffCaCyt)
domDisc:add(diffCaER)
domDisc:add(diffClb)
domDisc:add(diffIP3)

domDisc:add(discBuffer)

domDisc:add(discIP3R)
domDisc:add(discRyR)
domDisc:add(discSERCA)
domDisc:add(discERLeak)

domDisc:add(discPMCA)
domDisc:add(discNCX)
domDisc:add(discPMLeak)
--domDisc:add(discVDCC)

domDisc:add(synapseInfluxCa)
domDisc:add(synapseInfluxIP3)

--domDisc:add(uselessDofDiri)


-- setup time discretization --
timeDisc = ThetaTimeStep(domDisc)
timeDisc:set_theta(1.0) -- 1.0 is implicit Euler

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
	
    bcgs_steps = 1000
	bcgs_precond = gmg
end

convCheck:set_maximum_steps(bcgs_steps)

bicgstabSolver = BiCGStab()
bicgstabSolver:set_preconditioner(bcgs_precond)
bicgstabSolver:set_convergence_check(convCheck)
--bicgstabSolver:set_debug(dbgWriter)

--- non-linear solver ---
-- convergence check
newtonConvCheck = CompositeConvCheck(approxSpace, 10, 1e-17, 1e-10)
--newtonConvCheck:set_component_check("ca_cyt, ca_er, clb, ip3", 1e-18, 1e-10)
newtonConvCheck:set_verbose(true)
newtonConvCheck:set_time_measurement(true)
--newtonConvCheck:set_adaptive(true)

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


------------------
--  LIMEX setup --
------------------
nstages = 2            -- number of stages
stageNSteps = {1,2,3}  -- number of time steps for each stage
tol = 0.01             -- allowed relative error ()

-- convergence check
limexConvCheck = ConvCheck(1, 1e-18, 1e-08, true)
limexConvCheck:set_supress_unsuccessful(true)
newtonSolver:set_convergence_check(limexConvCheck)

limex = LimexTimeIntegrator(nstages)
for i = 1, nstages do
	limex:add_stage(stageNSteps[i], newtonSolver, domDisc)
end

limex:set_tolerance(tol)
limex:set_time_step(dt)
limex:set_dt_min(dtmin)
limex:set_dt_max(dtmax)
limex:set_increase_factor(2.0)

-- GridFunction error estimator (relative norm)
--errorEvaluator = L2ErrorEvaluator("ca_cyt", "cyt", 3, 1.0) -- function name, subset names, integration order, scale
errorEvaluator = SupErrorEvaluator("ca_cyt", "cyt", 1.0) -- function name, subset names, scale
limexEstimator = ScaledGridFunctionEstimator()
limexEstimator:add(errorEvaluator)
limex:add_error_estimator(limexEstimator)

-- for vtk output
if (generateVTKoutput) then 
	local vtkObserver = VTKOutputObserver(outDir .."vtk/solution", out, pstep)
	limex:attach_observer(vtkObserver)
end


--bicgstabSolver:set_debug(dbgWriter)
--newtonSolver:set_debug(dbgWriter)
--gmg:set_debug(dbgWriter)
--convCheck:set_maximum_steps(1)

-- solve problem
limex:apply(u, endTime, u, time)


if (generateVTKoutput) then 
	out:write_time_pvd(outDir .. "vtk/solution", u)
end

if doProfiling then
	WriteProfileData(outDir .."pd.pdxml")
end
