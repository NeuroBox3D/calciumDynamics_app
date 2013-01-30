----------------------------------------------------------------
--  Example script for simulation on 3d reconstructed neuron  --
--                                                            --
--  Author: Markus Breit                                      --
----------------------------------------------------------------

-- load pre-implemented lua functions
ug_load_script("ug_util.lua")

-- dimension
dim = 3

-- choose dimension and algebra
InitUG(dim, AlgebraType("CPU", 1));

-- choice of grid
gridName = "rc19/rc19_amp_singleDend.ugx"
--gridName = "rc19/rc19_amp_measZones.ugx"
--gridName = "rc19/rc19_amp_new.ugx"
--gridName = "rc19/rc19_amp.ugx"					-- deprecated
--gridName = "rc19/RC19amp_ug4_finished.ugx"		-- dead
--gridName = "simple_reticulum_3d.ugx"				-- for testing

-- refinements before distributing grid
numPreRefs = util.GetParamNumber("-numPreRefs", 0)

-- total refinements
numRefs = util.GetParamNumber("-numRefs",    0)

-- choose length of time step
timeStep = util.GetParamNumber("-tstep", 0.01)

-- choose end time
endTime = util.GetParamNumber("-endTime")
if (endTime == nil)
then
	-- choose number of time steps
	nTimeSteps = util.GetParamNumber("-nTimeSteps", 1)
	endTime = nTimeSteps*timeStep
end

-- chose plotting interval
plotStep = util.GetParamNumber("-pstep", 0.01)

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
ca_cyt_init = 4.0e-8
ca_er_init = 2.5e-4
ip3_init = 4.0e-8
clb_init = totalClb / (k_bind_clb/k_unbind_clb*ca_cyt_init + 1)


-- calmodulin --
totalClmd = 2*21.9e-6;

-- calmodulin diffusion coefficient
D_clm = 0.25;

-- calmodulin binding rates
k_bind_clmd_c = 	2.3e06
k_unbind_clmd_c = 	2.4
k_bind_clmd_n = 	1.6e08
k_unbind_clmd_n = 	405.0

-- initial concentrations
clmC_init = totalClmd / (k_bind_clmd_c/k_unbind_clmd_c*ca_cyt_init + 1)
clmN_init = totalClmd / (k_bind_clmd_n/k_unbind_clmd_n*ca_cyt_init + 1)


-- reaction reate IP3
reactionRateIP3 = 0.11

-- equilibrium concentration IP3
equilibriumIP3 = 4.0e-08

-- reation term IP3
reactionTermIP3 = -reactionRateIP3 * equilibriumIP3

---------------------------------------------------------------------
-- functions steering tempo-spatial parameterization of simulation --
---------------------------------------------------------------------
function CaCytStart(x, y, z, t)
    return ca_cyt_init
end

function CaERStart(x, y, z, t)
    return ca_er_init
end

function IP3Start(x, y, z, t)
    return ip3_init
end

function clbStart(x, y, z, t)
    return clb_init
end

function clmCStart(x, y, z, t)
    return clmC_init
end

function clmNStart(x, y, z, t)
    return clmN_init
end

function ourDiffTensorCAcyt(x, y, z, t)
    return	D_cac, 0, 0,
            0, D_cac, 0,
            0, 0, D_cac
end

function ourDiffTensorCAer(x, y, z, t)
    return	D_cae, 0, 0,
            0, D_cae, 0,
            0, 0, D_cae
end

function ourDiffTensorIP3(x, y, z, t)
    return	D_ip3, 0, 0,
            0, D_ip3, 0,
            0, 0, D_ip3
end

function ourDiffTensorClb(x, y, z, t)
    return	D_clb, 0, 0,
            0, D_clb, 0,
            0, 0, D_clb
end

function ourDiffTensorClm(x, y, z, t)
    return D_clm, 0, 0,
           0, D_clm, 0,
           0, 0, D_clm
end

-- density correction factor (simulates larger surface area of ER caused by stacking etc.)
dcf = 2.0


-- project coordinates on dendritic length from soma (approx.)
function dendLengthPos(x,y,z)
	return (0.92*(x-2.2) +0.39*(y+10.5) -0.04*(z+1.2)) / 110.0
end

function IP3Rdensity(x,y,z,t,si)
	local dens = math.abs(dendLengthPos(x,y,z))
	-- fourth order polynomial, distance to soma
	dens = 1.4 -2.8*dens +6.6*math.pow(dens,2) -7.0*math.pow(dens,3) +2.8*math.pow(dens,4)
	dens = dens * dcf * 17.3
	-- cluster for branching points
	if (si>=29 and si<=30) then dens = dens * 10 end 
	return dens
end

function RYRdensity(x,y,z,t,si)
	local dens = math.abs(dendLengthPos(x,y,z))
	-- fourth order polynomial, distance to soma
	dens = 1.5 -3.5*dens +9.1*math.pow(dens,2) -10.5*math.pow(dens,3) +4.3*math.pow(dens,4)
	dens = dens * dcf * 0.86; 
	return dens
end

-- this is a little bit more complicated, since it must be ensured that
-- the net flux for equilibrium concentrations is zero
-- MUST be adapted whenever any parameterization of ER flux mechanisms is changed!
function SERCAdensity(x,y,z,t,si)
	local v_s = 6.5e-27						-- V_S param of SERCA pump
	local k_s = 1.8e-7						-- K_S param of SERCA pump
	local j_ip3r = 2.7817352713488838e-23	-- single channel IP3R flux (mol/s) - to be determined via gdb
	local j_ryr = 4.6047720062808216e-22	-- single channel RyR flux (mol/s) - to be determined via gdb
	local j_leak = ca_er_init-ca_cyt_init	-- leak proportionality factor
	
	dens = 	  IP3Rdensity(x,y,z,t,si) * j_ip3r
			+ RYRdensity(x,y,z,t,si) * j_ryr
			+ LEAKERconstant(x,y,z,t,si) * j_leak
	dens = dens / (v_s/(k_s/ca_cyt_init+1.0)/ca_er_init)
	return dens
end

function LEAKERconstant(x,y,z,t,si)
	return dcf*3.4e-17
end

function PMCAdensity(x,y,z,t,si)
	return 100.0
end

function NCXdensity(x,y,z,t,si)
	return 3.0
end

function LEAKPMconstant(x,y,z,t,si)
	return 6.8e-22
end


function ourRhs(x, y, z, t)
    return 0;
end


-- firing pattern of the synapses
syns = {}
for i=6,13 do
	syns["start"..i] = 0.005*(i-6)
	syns["end"..i] = 0.005*(i-6)+0.01
end


-- burst of calcium influx for active synapses (~1200 ions)
function ourNeumannBndCA(x, y, z, t, si)
	if 	(si>=6 and si<=13 and syns["start"..si]<t and t<=syns["end"..si])
	--then efflux = -5e-6 * 11.0/16.0*(1.0+5.0/((10.0*(t-syns["start"..si])+1)*(10.0*(t-syns["start"..si])+1)))
	then efflux = -2e-4
	else efflux = 0.0
	end
    return true, efflux
end


-- burst of ip3 at active synapses (triangular, immediate)
ip3EntryDelay = 0.000
ip3EntryDuration = 2.0
function ourNeumannBndIP3(x, y, z, t, si)
	if 	(si>=6 and si<=13 and syns["start"..si]+ip3EntryDelay<t
	     and t<=syns["start"..si]+ip3EntryDelay+ip3EntryDuration)
	then efflux = - 2.1e-5/1.188 * (1.0 - (t-syns["start"..si])/ip3EntryDuration)
	else efflux = 0.0
	end
    return true, efflux
end

-------------------------------
-- setup approximation space --
-------------------------------
-- create, load, refine and distribute domain
print("create, refine and distribute domain")
neededSubsets = {}
distributionMethod = "metisReweigh"
weightingFct = InterSubsetEdgeWeighting()
weightingFct:set_default_weights(1,1)
weightingFct:set_indivisible_boundary_between_subsets(0, 1, 1000)
dom = util.CreateAndDistributeDomain(gridName, numRefs, numPreRefs, neededSubsets, distributionMethod, nil, nil, nil, weightingFct)

---[[
--print("Saving domain grid and hierarchy.")
--SaveDomain(dom, "refined_grid_p" .. GetProcessRank() .. ".ugx")
--SaveGridHierarchyTransformed(dom:grid(), "refined_grid_hierarchy_p" .. GetProcessRank() .. ".ugx", 20.0)
print("Saving parallel grid layout")
SaveParallelGridLayout(dom:grid(), "parallel_grid_layout_p"..GetProcessRank()..".ugx", 20.0)
--]]

-- create approximation space
print("Create ApproximationSpace")
approxSpace = ApproximationSpace(dom)

cytVol = "cyt"
measZones = ""
for i=1,15 do
	measZones = measZones .. ", measZone" .. i
end
cytVol = cytVol .. measZones

nucVol = "nuc"
nucMem = "mem_nuc"

erVol = "er"

plMem = "mem_cyt"
synapses = ""
for i=1,8 do
	synapses = synapses .. ", syn" .. i
end
plMem = plMem .. synapses

erMem = "mem_er"
branches = ""
for i=1,2 do
	branches = branches .. ", branch" .. i
end
erMem = erMem .. branches

outerDomain = cytVol .. ", " .. nucVol .. ", " .. nucMem .. ", " .. plMem .. ", " .. erMem
innerDomain = erVol .. ", " .. erMem

approxSpace:add_fct("ca_er", "Lagrange", 1, innerDomain)
approxSpace:add_fct("ca_cyt", "Lagrange", 1, outerDomain)
approxSpace:add_fct("ip3", "Lagrange", 1, outerDomain)
approxSpace:add_fct("clb", "Lagrange", 1, outerDomain)
--approxSpace:add_fct("clm_c", "Lagrange", 1, outerDomain)
--approxSpace:add_fct("clm_n", "Lagrange", 1, outerDomain)

approxSpace:init_levels()
approxSpace:print_layout_statistic()
approxSpace:print_statistic()

--------------------------
-- setup user functions --
--------------------------
print ("Setting up Assembling")

-- start value function setup
CaCytStartValue = LuaUserNumber3d("CaCytStart")
CaERStartValue = LuaUserNumber3d("CaERStart")
IP3StartValue = LuaUserNumber3d("IP3Start")
ClbStartValue = LuaUserNumber3d("clbStart")
ClmCStartValue = LuaUserNumber3d("clmCStart")
ClmNStartValue = LuaUserNumber3d("clmNStart")

-- diffusion Tensor setup
diffusionMatrixCAcyt = LuaUserMatrix3d("ourDiffTensorCAcyt")
diffusionMatrixCAer = LuaUserMatrix3d("ourDiffTensorCAer")
diffusionMatrixIP3 = LuaUserMatrix3d("ourDiffTensorIP3")
diffusionMatrixClb = LuaUserMatrix3d("ourDiffTensorClb")
diffusionMatrixClm = LuaUserMatrix3d("ourDiffTensorClm")

-- rhs setup
rhs = LuaUserNumber3d("ourRhs")

----------------------------------------------------------
-- setup FV convection-diffusion element discretization --
----------------------------------------------------------
-- Note: No VelocityField and Reaction is set. The assembling assumes default
--       zero values for them

if dim == 2 then 
    upwind = NoUpwind2d()
elseif dim == 3 then 
    upwind = NoUpwind3d()
end

elemDiscER = ConvectionDiffusion("ca_er", erVol) 
elemDiscER:set_disc_scheme("fv1")
elemDiscER:set_diffusion(diffusionMatrixCAer)
elemDiscER:set_source(rhs)
elemDiscER:set_upwind(upwind)

elemDiscCYT = ConvectionDiffusion("ca_cyt", cytVol..", "..nucVol)
elemDiscCYT:set_disc_scheme("fv1")
elemDiscCYT:set_diffusion(diffusionMatrixCAcyt)
elemDiscCYT:set_source(rhs)
elemDiscCYT:set_upwind(upwind)

elemDiscIP3 = ConvectionDiffusion("ip3", cytVol..", "..nucVol)
elemDiscIP3:set_disc_scheme("fv1")
elemDiscIP3:set_diffusion(diffusionMatrixIP3)
elemDiscIP3:set_reaction_rate(reactionRateIP3)
elemDiscIP3:set_reaction(reactionTermIP3)
elemDiscIP3:set_source(rhs)
elemDiscIP3:set_upwind(upwind)

elemDiscClb = ConvectionDiffusion("clb", cytVol..", "..nucVol)
elemDiscClb:set_disc_scheme("fv1")
elemDiscClb:set_diffusion(diffusionMatrixClb)
elemDiscClb:set_source(rhs)
elemDiscClb:set_upwind(upwind)

--[[
elemDiscClmC = ConvectionDiffusion("clm_c", cytVol..", "..nucVol)
elemDiscClb:set_disc_scheme("fv1")
elemDiscClb:set_diffusion(diffusionMatrixClm)
elemDiscClb:set_source(rhs)
elemDiscClb:set_upwind(upwind)

elemDiscClmN = ConvectionDiffusion("clm_n", cytVol..", "..nucVol)
elemDiscClb:set_disc_scheme("fv1")
elemDiscClb:set_diffusion(diffusionMatrixClm)
elemDiscClb:set_source(rhs)
elemDiscClb:set_upwind(upwind)
--]]
---------------------------------------
-- setup reaction terms of buffering --
---------------------------------------
elemDiscBuffering = FV1Buffer(cytVol)	-- where buffering occurs
elemDiscBuffering:add_reaction(
	"clb",						    -- the buffering substance
	"ca_cyt",						-- the buffered substance
	totalClb,						-- total amount of buffer
	k_bind_clb,					    -- binding rate constant
	k_unbind_clb)				    -- unbinding rate constant

--[[ Calmodulin
elemDiscBuffering_clm = FV1Buffer(cytVol)
elemDiscBuffering_clm:add_reaction(
	"clm_c",
	"ca_cyt",
	totalClmd,
	k_bind_clmd_c,
	k_unbind_clmd_c)
elemDiscBuffering_clm:add_reaction(
	"clm_n",
	"ca_cyt",				
	totalClmd,
	k_bind_clmd_n,
	k_unbind_clmd_n)
--]]

----------------------------------------------------
-- setup inner boundary (channels on ER membrane) --
----------------------------------------------------

-- We pass the function needed to evaluate the flux function here.
-- The order, in which the discrete fcts are passed, is crucial!
innerDiscIP3R = FV1InnerBoundaryIP3R("ca_cyt, ca_er, ip3", erMem)
innerDiscIP3R:set_density_function("IP3Rdensity")
innerDiscRyR = FV1InnerBoundaryRyR("ca_cyt, ca_er", erMem)
innerDiscRyR:set_density_function("RYRdensity")
innerDiscSERCA = FV1InnerBoundarySERCA("ca_cyt, ca_er", erMem)
innerDiscSERCA:set_density_function("SERCAdensity")
innerDiscLeak = FV1InnerBoundaryERLeak("ca_cyt, ca_er", erMem)
innerDiscLeak:set_density_function("LEAKERconstant")

------------------------------
-- setup Neumann boundaries --
------------------------------
-- synaptic activity
neumannDiscCA = NeumannBoundary("cyt")
neumannDiscCA:add("ourNeumannBndCA", "ca_cyt", plMem)
neumannDiscIP3 = NeumannBoundary("cyt")
neumannDiscIP3:add("ourNeumannBndIP3", "ip3", plMem)
-- plasma membrane transport systems
neumannDiscPMCA = FV1BoundaryPMCA("ca_cyt", plMem)
neumannDiscPMCA:set_density_function("PMCAdensity")
neumannDiscNCX = FV1BoundaryNCX("ca_cyt", plMem)
neumannDiscNCX:set_density_function("NCXdensity")
neumannDiscLeak = FV1BoundaryPMLeak("", plMem)
neumannDiscLeak:set_density_function("LEAKPMconstant")


------------------------------------------
-- setup complete domain discretization --
------------------------------------------
domainDisc = DomainDiscretization(approxSpace)

-- diffusion discretizations
domainDisc:add(elemDiscER)
domainDisc:add(elemDiscCYT)
domainDisc:add(elemDiscIP3)
domainDisc:add(elemDiscClb)
--domainDisc:add(elemDiscClmC)
--domainDisc:add(elemDiscClmN)

-- buffering disc
domainDisc:add(elemDiscBuffering)
--domainDisc:add(elemDiscBuffering_clm)

-- (outer) boundary conditions
domainDisc:add(neumannDiscCA)
domainDisc:add(neumannDiscIP3)
domainDisc:add(neumannDiscPMCA)
domainDisc:add(neumannDiscNCX)
domainDisc:add(neumannDiscLeak)

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
base = LinearSolver()
base:set_convergence_check(baseConvCheck)
base:set_preconditioner(gs)

gmg = GeometricMultiGrid(approxSpace)
gmg:set_discretization(timeDisc)
gmg:set_base_level(0)
gmg:set_base_solver(base)
gmg:set_smoother(gs)
gmg:set_cycle_type(1)
gmg:set_num_presmooth(3)
gmg:set_num_postsmooth(3)

-- biCGstab --
convCheck = ConvCheck()
convCheck:set_maximum_steps(2000)		-- more here for gs alternative
convCheck:set_minimum_defect(1e-24)
convCheck:set_reduction(1e-06)
convCheck:set_verbose(false)
bicgstabSolver = BiCGStab()
bicgstabSolver:set_preconditioner(gs)	-- or just gs
bicgstabSolver:set_convergence_check(convCheck)

-----------------------
-- non linear solver --
-----------------------
-- convergence check
newtonConvCheck = CompositeConvCheck3dCPU1(approxSpace)
newtonConvCheck:set_functions("")
newtonConvCheck:set_maximum_steps(10)
newtonConvCheck:set_minimum_defect({}, 1e-18)
newtonConvCheck:set_reduction({}, 1e-08)
newtonConvCheck:set_verbose(true)
newtonConvCheck:timeMeasurement(true)
--[[
newtonConvCheck = ConvCheck()
newtonConvCheck:set_maximum_steps(20)
newtonConvCheck:set_minimum_defect(1e-21)
newtonConvCheck:set_reduction(1e-08)
newtonConvCheck:set_verbose(true)
--]]

-- Newton solver
newtonSolver = NewtonSolver()
newtonSolver:set_linear_solver(bicgstabSolver)
newtonSolver:set_convergence_check(newtonConvCheck)

newtonSolver:init(op)

-------------
-- solving --
-------------

-- get grid function
u = GridFunction(approxSpace)

-- set initial value
Interpolate(CaCytStartValue, u, "ca_cyt", 0.0)
Interpolate(CaERStartValue, u, "ca_er", 0.0)
Interpolate(IP3StartValue, u, "ip3", 0.0)
Interpolate(ClbStartValue, u, "clb", 0.0)


-- timestep in seconds
dt = timeStep
time = 0.0
step = 0

-- filename
fileName = "rc19/"

-- write start solution
print("Writing start values")
out = VTKOutput()
out:print(fileName .. "vtk/result", u, step, time)
takeMeasurement(u, approxSpace, time, "nuc", "ca_cyt", fileName .. "meas/nuc")
for i=1,15 do
	takeMeasurement(u, approxSpace, time, "measZone"..i, "ca_cyt, ip3, clb", fileName .. "meas/meas"..i)
end
--exportSolution(u, approxSpace, time, "mem_cyt", "ca_cyt", fileName .. "sol/sol");


-- create new grid function for old value
uOld = u:clone()

-- store grid function in vector of  old solutions
solTimeSeries = SolutionTimeSeries()
solTimeSeries:push(uOld, time)


min_dt = timeStep / math.pow(2,15)
cb_interval = 10
lv = 0
cb_counter = {}
cb_counter[0] = 0
while endTime-time > 0.001*dt do
	print("++++++ POINT IN TIME  " .. math.floor((time+dt)/dt+0.5)*dt .. "s  BEGIN ++++++")
	
	-- setup time Disc for old solutions and timestep
	timeDisc:prepare_step(solTimeSeries, dt)
	
	-- prepare newton solver
	if newtonSolver:prepare(u) == false then print ("Newton solver failed at step "..step.."."); exit(); end 
	
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
		while cb_counter[lv] % (2*cb_interval) == 0 and lv > 0 do
			dt = 2*dt;
			lv = lv - 1
			cb_counter[lv] = cb_counter[lv] + cb_counter[lv+1] / 2
			cb_counter[lv+1] = 0
		end
		
		-- plot solution every plotStep seconds
		if math.abs(time/plotStep - math.floor(time/plotStep+0.5)) < 1e-5
		then out:print(fileName .. "vtk/result", u, math.floor(time/plotStep+0.5), time)
		end
		
		-- take measurement in nucleus every timeStep seconds 
		--if math.abs(time/timeStep - math.floor(time/timeStep+0.5)) < 1e-5
		--then
			takeMeasurement(u, approxSpace, time, "nuc", "ca_cyt", fileName .. "meas/nuc")
			for i=1,15 do
				takeMeasurement(u, approxSpace, time, "measZone"..i, "ca_cyt, ip3, clb", fileName .. "meas/meas"..i)
			end
		--end
				
		-- export solution of ca on mem_er
		--exportSolution(u, approxSpace, time, "mem_cyt", "ca_cyt", fileName .. "sol/sol");
		
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
out:write_time_pvd(fileName .. "vtk/result", u)

--[[
-- check if profiler is available
if GetProfilerAvailable() == true then
    print("")
    -- get node
    pn = GetProfileNode("main")
--    pn2 = GetProfileNode("GMG_lmgc")
    -- check if node is valid
    if pn:is_valid() then
	    print(pn:call_tree(0.0))
	    print(pn:groups())
--        print(pn2:total_time_sorted())
    else
        print("main is not known to the profiler.")
    end
else
    print("Profiler not available.")
end
--]]
