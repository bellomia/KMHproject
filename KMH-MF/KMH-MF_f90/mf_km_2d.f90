program mf_km_2d
  USE SCIFOR
  USE DMFT_TOOLS
  implicit none


  integer                                       :: Nparams  !#{order_parameters}
  integer,parameter                             :: Norb=1,Nspin=2,Nlat=2,Nlso=Nlat*Nspin*Norb
  integer                                       :: Nk,Nktot,Nkpath,Nkx,Nky,L
  integer                                       :: unit_p,unit_e
  integer                                       :: i,j,k,ik,iorb,jorb,ispin,io,jo
  integer                                       :: ilat,jlat
  integer                                       :: ix,iy,iz
  real(8)                                       :: kx,ky,kz
  real(8),dimension(:,:),allocatable            :: kgrid,kpath
  real(8),dimension(2)                          :: e1,e2    !real-space lattice basis
  real(8),dimension(2)                          :: bk1,bk2  !reciprocal space lattice basis
  real(8),dimension(2)                          :: d1,d2,d3 !unit-cell displacements
  real(8),dimension(2)                          :: a1,a2,a3 !inter-cell displacements
  real(8)                                       :: bklen

  complex(8),dimension(:,:,:),allocatable       :: Hk
  integer 					                        :: Iter,MaxIter,Nsuccess=2
  real(8)                                       :: Uloc
  !
  !variables for the model:
  character(len=32)                             :: finput
  real(8)                                       :: t1,t2,phi,Mh,wmixing,lambda
  real(8)                                       :: xmu,beta,eps
  real(8)                                       :: wmix,it_error,sb_field
  complex(8)                                    :: Hmf_glob(Nlso,Nlso)
  complex(8),dimension(:,:,:,:,:,:),allocatable :: Gmats,Greal
  character(len=20)                             :: file
  logical                                       :: iexist,converged,withgf,getbands
  complex(8),dimension(Nlso,Nlso)               :: Gamma0,GammaX,GammaY,GammaZ,Gamma5
  complex(8),dimension(Nlso,Nlso)               :: GammaSz,GammaSx,GammaSy
  complex(8),dimension(Nlso,Nlso)               :: GammaRz,GammaRx,GammaRy
  real(8),dimension(:),allocatable              :: params,params_prev

  call parse_cmd_variable(Finput,"FINPUT",default="inputKM.conf")
  call parse_input_variable(Nparams,"NPARAMS",Finput,default=6,comment="2=AFMz,4=AFMxy,6=AFMxyz")
  call parse_input_variable(nkx,"NKX",Finput,default=25,comment='Number of k-points per direction, for full BZ sampling')
  call parse_input_variable(nkpath,"NKPATH",Finput,default=500,comment='Number of k-points for bandstructure [requires GETBANDS]')
  call parse_input_variable(L,"L",Finput,default=2048,comment='Number of real and matsubara frequencies')
  call parse_input_variable(Uloc,"ULOC",Finput,default=1d0,comment='Local Hubbard interaction')
  call parse_input_variable(t1,"T1",finput,default=1d0,comment='NN hopping, fixes noninteracting bandwidth')
  call parse_input_variable(t2,"T2",finput,default=0d0,comment='Haldane-like NNN hopping-strenght, corresponds to lambda_SO in KM notation')
  call parse_input_variable(mh,"MH",Finput,default=0d0,comment='On-site staggering, aka Semenoff-Mass term')
  call parse_input_variable(xmu,"XMU",Finput,default=0.d0,comment='Chemical potential [0 <-> half-filling]')
  call parse_input_variable(eps,"EPS",Finput,default=4.d-2,comment='Broadening on the real-axis')
  call parse_input_variable(beta,"BETA",Finput,default=1000.d0,comment='Inverse temperature')
  call parse_input_variable(wmix,"WMIX",Finput,default=0.5d0,comment='Mixing parameter: 0 for no update at all, 1 for a pure unmixed update')
  call parse_input_variable(sb_field,"SB_FIELD",Finput,default=0.1d0,comment='Symmetry-breaking kick amplitude')
  call parse_input_variable(it_error,"IT_ERROR",Finput,default=1d-5,comment='Relative threshold for self-consistent solution')
  call parse_input_variable(maxiter,"NLOOP",Finput,default=1000,comment='Maximum number of iterarations')
  call parse_input_variable(withgf,"WITHGF",Finput,default=.false.,comment='If T computes mean-field GFs from converged/maxiterated solution')
  call parse_input_variable(getbands,"GETBANDS",Finput,default=.true.,comment='If T computes mean-field bandstructure along standard k-path')
  !
  call print_input(trim(Finput))
  call save_input_file(trim(Finput))
  !
  call add_ctrl_var(beta,"BETA")
  call add_ctrl_var(Norb,"NORB")
  call add_ctrl_var(Nspin,"Nspin")
  call add_ctrl_var(xmu,"xmu")
  call add_ctrl_var(-10d0,"wini")
  call add_ctrl_var(10d0,"wfin")
  call add_ctrl_var(eps,"eps")

  select case(Nparams)
  case default
     stop "Wrong NPARAMS != [2,4,6]"
  case (2)
     write(*,*)"Solving KMH-MF with Z-magnetization: [Sz,Rz]"
  case (4)
     write(*,*)"Solving KMH-MF with XY-magnetization: [Sx,Sy,Rx,Ry]"
  case (6)
     write(*,*)"Solving KMH-MF with XYZ-magnetization: [Sx,Sy,Sz,Rx,Ry,Rz] "
  end select

  Nky  = Nkx
  Nktot= Nkx*Nky
  !
  allocate( params(Nparams), params_prev(Nparams) )

  !SETUP THE GAMMA MATRICES:
  !we must use the basis \Gamma_ab = \tau_a \circ \sigma_b
  ! tau_a   -> lattice
  ! sigma_b -> spin
  ! \psi = [A_up, A_dw; B_up, B_dw]^T
  !This convention is dictated by the use of DMFT_TOOLS
  gamma0=kron_pauli( pauli_tau_0, pauli_sigma_0) !G_00
  gammaZ=kron_pauli( pauli_tau_z, pauli_sigma_z) !G_33
  gammaX=kron_pauli( pauli_tau_x, pauli_sigma_0) !G_10
  gammaY=kron_pauli( pauli_tau_y, pauli_sigma_0) !G_20
  gamma5=kron_pauli( pauli_tau_0, pauli_sigma_z) !G_03
  !
  gammaSx=kron_pauli( pauli_tau_0, pauli_sigma_x )
  gammaSy=kron_pauli( pauli_tau_0, pauli_sigma_y )
  gammaSz=kron_pauli( pauli_tau_0, pauli_sigma_z )
  gammaRx=kron_pauli( pauli_tau_z, pauli_sigma_x )
  gammaRy=kron_pauli( pauli_tau_z, pauli_sigma_y )
  gammaRz=kron_pauli( pauli_tau_z, pauli_sigma_z )

  !SETUP THE HONEYCOMB LATTICE
  !
  !Lattice basis is:
  !e₁ = a₀ [ sqrt3/2 , 1/2 ] = 3/2a[1, 1/sqrt3]
  !e₂ = a₀ [ sqrt3/2 ,-1/2 ] = 3/2a[1,-1/sqrt3]
  !where a = 1 and a₀ = sqrt3 * a
  e1 = 3d0/2d0*[1d0, 1d0/sqrt(3d0)]
  e2 = 3d0/2d0*[1d0,-1d0/sqrt(3d0)]
  !
  !Unit-cell displacements: nearest neighbor A-->B, B-->A
  d1= [  1d0/2d0 , sqrt(3d0)/2d0 ]
  d2= [  1d0/2d0 ,-sqrt(3d0)/2d0 ]
  d3= [ -1d0     , 0d0           ]
  !
  !Cell displacements: next nearest-neighbor A-->A, B-->B
  a1 = d1-d3   !3/2*a[1,1/sqrt3]
  a2 = d2-d3   !3/2*a[1,-1/sqrt3]
  a3 = d1-d2   !sqrt3[0,1]
  
  !RECIPROCAL LATTICE VECTORS
  bklen=2d0*pi/3d0
  bk1=bklen*[ 1d0, sqrt(3d0)] 
  bk2=bklen*[ 1d0,-sqrt(3d0)]
  call TB_set_bk(bkx=bk1,bky=bk2)
  
  !BRILLOUIN ZONE SAMPLING
  allocate(kgrid(Nktot,2)) !Nktot=#{kpoints on x}*#{kpoints on y}, 2->2D
  call TB_build_kgrid([Nkx,Nky],kgrid) !Filling the grid

  !INIT MAGNETIC ORDER PARAMETERS
  params = sb_field ! Kick on all magnetic orders
  inquire(file="params.restart",exist=iexist)
  if(iexist)then
     call read_array("params.restart",params)
     !Kick unbroken symmetries anyway: avoid getting stuck on metastable solutions
     where(params<sb_field)params=params+sb_field
  endif
  call save_array("params.init",params) !Save used initial parameters, for reproducibility
  
  !SETUP I/O FILES
  unit_p = free_unit()
  select case(Nparams)
    case(2)
       open(unit_p,file="order_parameters_Sz_Rz.dat")
    case(4)
       open(unit_p,file="order_parameters_Sx_Sy_Rx_Ry.dat")
    case(6)
       open(unit_p,file="order_parameters_Sx_Sy_Sz_Rx_Ry_Rz.dat")
  end select
  !
  unit_e = free_unit()
  open(unit_e,file="mean_field_gs.dat")

  !SELF-CONSISTENT LOOP
  converged=.false. ; iter=0
  do while(.not.converged.AND.iter<maxiter)
     iter=iter+1
     call start_loop(iter,maxiter,"MF-loop")
     !
     call solve_MF_loc(params,Hmf_glob)
     if(iter>1)params = wmix*params + (1d0-wmix)*params_prev
     params_prev = params
     !
     converged = check_convergence_local(params,it_error,nsuccess,maxiter) 
     !
     call end_loop
  end do
  call save_array("params.restart",params)
  close(unit_p)
  close(unit_e)
  !
  !Update global mean-field hamiltonian correction 
  !-> to be used within subsequent hk_mf_model calls
  call TB_write_hloc(Hmf_glob)

  if(withgf)then
      !Build mean-field green's functions
      allocate(Hk(Nlso,Nlso,Nktot))
      call TB_build_model(Hk,hk_mf_model,Nlso,[Nkx,Nkx])
      allocate(Gmats(Nlat,Nspin,Nspin,Norb,Norb,L))
      allocate(Greal(Nlat,Nspin,Nspin,Norb,Norb,L))
      call dmft_gloc_matsubara(Hk,Gmats,zeros(Nlat,Nspin,Nspin,Norb,Norb,L))
      call dmft_gloc_realaxis(Hk,Greal,zeros(Nlat,Nspin,Nspin,Norb,Norb,L))
      !Print to file
      call dmft_print_gf_matsubara(Gmats,"Gmats",iprint=4)
      call dmft_print_gf_realaxis(Greal,"Greal",iprint=4)
  endif

  !SOLVE MEAN-FIELD HAMILTONIAN ALONG STANDARD HONEYCOMB PATH
  if(getbands)then
      allocate(Kpath(4,2))
      KPath(1,:)=[0,0]
      KPath(2,:)=[2*pi/3, 2*pi/3/sqrt(3d0)]
      Kpath(3,:)=[2*pi/3,-2*pi/3/sqrt(3d0)]
      KPath(4,:)=[0d0,0d0]
      call TB_Solve_model(hk_mf_model,Nlso,KPath,Nkpath,&
         colors_name=[red,blue,tomato,aquamarine],& !\psi=[A_up,A_dw;B_up,B_dw]
         points_name=[character(len=10) :: "{/Symbol G}","K","K`","{/Symbol G}"],&
         file="EigenbandsKMH.mf",iproject=.false.)
  endif



contains



  !Noninteracting H(k) model
  function hk_model(kpoint,N) result(hk)    
      real(8),dimension(:)      :: kpoint
      integer                   :: N
      complex(8),dimension(N,N) :: hk
      real(8)                   :: h0,hx,hy,hz
      real(8)		      :: kdote1, kdote2
      !
      kdote1 = dot_product(kpoint,e1)
      kdote2 = dot_product(kpoint,e2)
      !
      hx = t1*( cos(kdote1) + cos(kdote2) + 1)
      hy = t1*( sin(kdote1) + sin(kdote2) )
      hz = 2*t2*( sin(kdote1) - sin(kdote2) - sin(kdote1-kdote2) )
      !
      !Using \psi=[A_up,A_dw;B_up,B_dw]
      Hk = hx*GammaX + hy*GammaY + hz*GammaZ + Mh*Gamma5
      !
  end function hk_model
  !
  !Mean-Field corrected H(k) model
  function hk_mf_model(kpoint,N) result(hk)
      real(8),dimension(:)      :: kpoint
      integer                   :: N
      complex(8),dimension(N,N) :: hk
      !
      !Noninteracting + mean-field correction
      hk = hk_model(kpoint,N) + hmf_glob
      !
  end function hk_mf_model



  !Solve the local mean-field model and build iterated order parameters
  subroutine solve_MF_loc(order_parameters,mf_correction)
      real(8),dimension(:),intent(inout)           :: order_parameters
      complex(8),dimension(Nlso,Nlso),intent(out)  :: mf_correction
      real(8),dimension(2)               :: kvec
      complex(8),dimension(Nlso,Nlso)    :: Hk,HkMF
      real(8),dimension(Nlso)            :: Ek,rhoDiag
      logical,dimension(Nlso)            :: valence=.false.
      complex(8),dimension(Nlso,Nlso)    :: rhoHk,rhoH
      real(8)                            :: Emf
      real(8)                            :: Sx,Sy,Sz,Rx,Ry,Rz
      integer                            :: ik
      !
      Sx = 0d0; Rx = 0d0
      Sy = 0d0; Ry = 0d0
      Sz = 0d0; Rz = 0d0
      !
      HkMF = mf_hk_correction(order_parameters)
      !
      rhoH = 0d0
      Emf  = 0d0
      !SOLVE IN THE WHOLE BZ -> Get rhoH(k) = < H(k) | rho | H(k) >
      do ik=1,Nktot
         kvec = kgrid(ik,:)              ![kx,ky]
         Hk   = hk_model(kvec,Nlso)+HkMF !H(k)
         !
         call eigh(Hk,Ek)  !diag Hk --> Ek
         !
         rhoDiag = fermi(Ek,beta)
         rhoHk   = matmul( Hk, matmul(diag(rhoDiag),conjg(transpose(Hk))) )
      !GET LOCAL SOLUTION -> \rhoH_loc = \sum_k \rhoH(k)
         rhoH    = rhoH + rhoHk/Nktot
      !GET MF GROUND-STATE ENERGY -> Emf = \sum_k Eᵥ(k), Eᵥ(k): negative E(k)
         where(Ek<0d0)valence=.true.
         Emf = Emf + sum(Ek, mask=valence) / (Nktot*Nlat) !We want energy/site
      enddo
      !Print MF-GS energy
      write(*,*)"∫_{BZ}Eᵥ(k)dk = "//str(Emf)
      rewind(unit_e)
      write(unit_e,"(F21.12)")Emf
      !
      !Update order parameters and print to stdout + file
      Sx = Sx + sum( GammaSx*rhoH )
      Sy = Sy - sum( GammaSy*rhoH )
      Sz = Sz + sum( GammaSz*rhoH )
      Rx = Rx + sum( GammaRx*rhoH )
      Ry = Ry - sum( GammaRy*rhoH )
      Rz = Rz + sum( GammaRz*rhoH )
      !
      select case(Nparams)
      case(2)
         order_parameters = [Sz,Rz]
         write(*,*)"Sz Rz:"
         write(*,"(2F21.12)")Sz,Rz
         rewind(unit_p)
         write(unit_p,"(2F21.12)")Sz,Rz
      case(4)
         order_parameters = [Sx,Sy,Rx,Ry]
         write(*,*)"Sx Sy Rx Ry:"
         write(*,"(4F21.12)")Sx,Sy,Rx,Ry
         rewind(unit_p)
         write(unit_p,"(4F21.12)")Sx,Sy,Rx,Ry
      case(6)
         order_parameters = [Sx,Sy,Sz,Rx,Ry,Rz]
         write(*,*)"Sx Sy Sz Rx Ry Rz:"
         write(*,"(12F21.12)")Sx,Sy,Sz,Rx,Ry,Rz
         rewind(unit_p)
         write(unit_p,"(6F21.12)")Sx,Sy,Sz,Rx,Ry,Rz
      end select
      !
      !Return mean-field correction to H(k) to parent scope
      mf_correction = HkMF
      !
      return
      !
  end subroutine solve_MF_loc


  !Build mean-field correction to H(k) from given order parameters
  function mf_Hk_correction(a) result(HkMF)
      real(8),dimension(:)            :: a    ! order parameters array
      complex(8),dimension(Nlso,Nlso) :: HkMF ! mean-field term in H(k)
      !
      select case(Nparams)
         !
         case(2)
         HkMF = a(1)*GammaSz + a(2)*GammaRz
         case(4)
         HkMF = a(1)*GammaSx + a(2)*GammaSy &
                  + a(3)*GammaRx + a(4)*GammaRy
         case(6)
         HkMF = a(1)*GammaSx + a(2)*GammaSy &
                  + a(3)*GammaRx + a(4)*GammaRy &
                  + a(5)*GammaSz + a(6)*GammaRz
         !
      end select
      !
      HkMF = -HkMf * Uloc/4d0
      !
  end function mf_Hk_correction




end program mf_km_2d



