!
! Copyright (C) 2023 Quantum ESPRESSO group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
MODULE vloc_mod
  !
  !! Variables and routines for local pseudopotential in numerical form
  !! Contains generation of interpolation tables in reciprocal space,
  !! interpolation routines and other utility routines
  !! Code moved to upflib and restructured by Paolo Giannozzi, 2023
  !
  USE upf_kinds,    ONLY : dp
  USE upf_const,    ONLY : fpi, e2, eps8
  !
  IMPLICIT NONE
  !
  PRIVATE
  PUBLIC :: init_tab_vloc
  PUBLIC :: deallocate_tab_vloc
  PUBLIC :: scale_tab_vloc
  PUBLIC :: vloc_of_g
  PUBLIC ::dvloc_of_g
  !
  SAVE
  !
  INTEGER :: nqx = 0
  !! size of interpolation table
  REAL(DP), PARAMETER:: dq = 0.01_dp
  !! grid step for interpolation table
  REAL(DP) :: qmax = 0.0_dp 
  !! max q covered by the interpolation table
  REAL(DP), ALLOCATABLE :: tab_vloc(:,:)
  !! interpolation table for numerical pseudopotentials
  !
CONTAINS
  !----------------------------------------------------------------------
  SUBROUTINE init_tab_vloc (qmax_, modified_coulomb, omega, comm,&
       ierr)
    !----------------------------------------------------------------------
    !
    !! Allocate and fill interpolation table for numerical pseudopotentials
    !! Output: tab_vloc(i,n) = V_n(q_i) where V_n(q_i) is the Fourier transform
    !! of the local potential MINUS the long-range term (see below) for atom
    !! type n on grid q_i=(i-1)*dq extending up to qmax.
    !! A term erf(r)/r is subtracted in real space (thus making the
    !! function short-ranged) and added again in G space (for G<>0)
    !! The G=0 term contains \int (V_loc(r)+ Ze^2/r) 4pi r^2 dr.
    !! This is the "alpha" in the so-called "alpha Z" term of the energy.
    !! Atomic Ry units everywhere.
    !
    USE upf_const,    ONLY : fpi, e2
    USE atom,         ONLY : rgrid, msh
    USE uspp_param,   ONLY : upf, nsp
    USE mp,           ONLY : mp_sum
    USE m_gth,        ONLY : vloc_gth
    !
    IMPLICIT NONE
    !
    INTEGER, INTENT(IN)  :: comm
    !! MPI communicator, to split the workload
    LOGICAL, INTENT(IN)  :: modified_coulomb
    !! if true subtract out a modified Coulomb potential
    INTEGER, INTENT(OUT) :: ierr
    !! error code: ierr = 1 if modifed Coulomb not implemented 
    REAL(dp), INTENT(IN) :: omega
    !! Unit-cell volume
    REAL(dp), INTENT(IN) :: qmax_
    !! Interpolate q up to qmax_ (sqrt(Ry), q^2 is an energy)
    INTEGER :: ndm, startq, lastq, nt, iq, ir
    !! Auxiliary variables and indices
    REAL(dp) :: r, q, q2(1)
    !! Auxiliary variables
    REAL(dp), ALLOCATABLE :: aux (:)
    !! Work space
    !
    IF ( modified_coulomb .AND. &
         ANY (upf(:)%is_gth .OR. upf(:)%tcoulombp) ) THEN
       ierr = 1
       RETURN
    END IF
    ierr = 0
    !
    IF ( .NOT. ALLOCATED(tab_vloc) ) THEN
       !! table not yet allocated
       qmax = qmax_
       nqx = INT( qmax/dq + 4)
       ALLOCATE ( tab_vloc(nqx,nsp) )
       !$acc enter data create(tab_vloc)
    ELSE IF ( qmax_ > qmax ) THEN
       DEALLOCATE ( tab_vloc )
       !! table ìs allocated but dimension insufficient: re-allocate
       !! (with some margin so that this does not happen too often)
       qmax = qmax_ + MAX(dq,qmax_-qmax) * 10
       nqx = INT( qmax/dq + 4)
       ALLOCATE ( tab_vloc(nqx,nsp) )
       !$acc enter data create(tab_vloc)
    ELSE
       RETURN
    END IF
    !
    ndm = MAXVAL( msh(1:nsp) )
    ALLOCATE (aux(ndm))
    !
    CALL divide (comm, nqx, startq, lastq)
    !
    DO nt = 1, nsp
       !
       tab_vloc(:,nt)= 0.d0
       !
       IF ( upf(nt)%is_gth ) THEN
          !! Compute analytical transform of GTH PP even if not actually used
          !! For testing purposes
          DO iq = startq, lastq
             q2(1) = ( (iq-1)*dq )**2
             CALL vloc_gth( nt, upf(nt)%zp, 1.0_dp, 1, q2, omega, tab_vloc(iq,nt) )
          END DO
       ELSE IF ( .NOT.upf(nt)%tcoulombp ) THEN
          !! If pure Coulomb potential, do nothing
          !
          DO iq = startq, lastq
             !
             q = (iq - 1) * dq
             DO ir = 1, msh(nt)
                r = rgrid(nt)%r(ir)
                aux (ir) = upf(nt)%vloc(ir) 
                IF ( iq > 1 ) THEN
                   !! q > 0 case: notice removal of erf(r)/r term
                   aux (ir) = (r*aux(ir) + upf(nt)%zp*e2*erf(r)) * sin(q*r)/q
                ELSE
                   !! The q = 0 case require a special treatment
                   IF ( modified_coulomb ) THEN
                      aux (ir) = r * ( r*aux(ir) + upf(nt)%zp*e2 * erf(r) )
                   ELSE
                      aux (ir) = r * ( r*aux(ir) + upf(nt)%zp*e2 )
                   ENDIF
                END IF
             ENDDO
             !
             CALL simpson ( msh(nt), aux, rgrid(nt)%rab, tab_vloc(iq,nt) )
             tab_vloc (iq,nt) = tab_vloc (iq,nt) * fpi / omega 
             !
          ENDDO
          !
       END IF
       !
    END DO
    !
    CALL mp_sum ( tab_vloc, comm )
    !$acc update device (tab_vloc)
    !
    DEALLOCATE (aux)
    !
  END SUBROUTINE init_tab_vloc
  !
  !-----------------------------------------------------------------------
  SUBROUTINE interp_vloc( nt, ngl, gl, tpiba2, vlocg )
  !-----------------------------------------------------------------------
  !! Interpolate the radial Fourier transform of the short-range local
  !! potential using the interpolation table previously computed 
  !
  INTEGER, INTENT(IN) :: nt
  !! atomic type
  INTEGER, INTENT(IN) :: ngl
  !! the number of G shells
  REAL(DP), INTENT(IN) :: gl(ngl)
  !! the list of |G|^2 of the shells
  REAL(DP), INTENT(IN) :: tpiba2
  !! 2 times pi / alat
  REAL(DP), INTENT(OUT) :: vlocg(ngl)
  !! the Fourier transform of the local potential (short-range only)
  !
  REAL(DP) :: gx, px, ux, vx, wx
  ! the modulus of g for a given shell
  ! variables used for interpolation
  INTEGER :: igl, i0, i1, i2, i3
  ! counters
  !
  !$acc data present_or_copyin(gl) present_or_copyout(vlocg) present(tab_vloc)
  !$acc parallel loop
  DO igl = 1, ngl
     gx = SQRT(gl(igl) * tpiba2)
     px = gx / dq - int (gx/dq)
     ux = 1.d0 - px
     vx = 2.d0 - px
     wx = 3.d0 - px
     i0 = INT(gx/dq) + 1
     i1 = i0 + 1
     i2 = i0 + 2
     i3 = i0 + 3
     vlocg (igl) = tab_vloc(i0, nt) * ux * vx * wx / 6.d0 + &
                   tab_vloc(i1, nt) * px * vx * wx / 2.d0 - &
                   tab_vloc(i2, nt) * px * ux * wx / 2.d0 + &
                   tab_vloc(i3, nt) * px * ux * vx / 6.d0

  ENDDO
  !$acc end data
  !
  END SUBROUTINE interp_vloc
  !-----------------------------------------------------------------------
  SUBROUTINE scale_tab_vloc ( vol_ratio_m1 )
    !-----------------------------------------------------------------------
    REAL(dp), INTENT(in) :: vol_ratio_m1
    tab_vloc(:,:) = tab_vloc(:,:) * vol_ratio_m1
    !$acc update device (tab_vloc)
  END SUBROUTINE scale_tab_vloc
  !
  !-----------------------------------------------------------------------
  SUBROUTINE deallocate_tab_vloc ( )
  !-----------------------------------------------------------------------
    !$acc exit data delete(tab_vloc)
    DEALLOCATE (tab_vloc)
    nqx = 0
    qmax = 0.0_dp
  END SUBROUTINE deallocate_tab_vloc
  !
  !----------------------------------------------------------------------
  SUBROUTINE vloc_of_g( nt, ngl, gl, tpiba2, modified_coulomb, omega, &
                vloc )
  !----------------------------------------------------------------------
  !! This routine computes the Fourier transform of the local part of an
  !! atomic pseudopotential, using an interpolation table for short-range
  !! terms, analytical results for the long-range terms
  !  
  USE uspp_param,   ONLY : upf
  USE m_gth,        ONLY : vloc_gth
  !
  IMPLICIT NONE
  !
  INTEGER, INTENT(IN) :: nt
  !! the index of type of pseudopotential
  INTEGER, INTENT(IN) :: ngl
  !! the number of shells of G vectors
  LOGICAL, INTENT(IN) :: modified_coulomb
  !! for ESM and 2D calculations
  REAL(DP), INTENT(IN) :: tpiba2
  !! 2 pi / alat
  REAL(DP), INTENT(IN) :: omega
  !! the volume of the unit cell
  REAL(DP), INTENT(IN) :: gl(ngl)
  !! the (ordered!) moduli of g vectors for each shell 
  REAL(DP), INTENT(OUT) :: vloc(ngl)
  !! the fourier transform of the potential
  !
  ! ... local variables
  !
  REAL(DP) :: fac
  ! auxiliary variables
  INTEGER :: igl, igl0
  ! igl : counter on g shells vectors
  ! igl0: position of first nonzero G
  !
  IF (gl (1) < eps8) THEN
     igl0 = 2
  ELSE
     igl0 = 1
  END IF
  !
  IF ( upf(nt)%is_gth ) THEN
     ! special case: GTH pseudopotential
     CALL vloc_gth( nt, upf(nt)%zp, tpiba2, ngl, gl, omega, vloc )
  ELSE IF ( upf(nt)%tcoulombp ) THEN
     ! special case: pure Coulomb pseudopotential
     IF ( igl0 > 1 ) vloc(1) = 0.0_dp
     vloc (igl0:ngl) = - fpi * upf(nt)%zp*e2 / omega / tpiba2 / gl (igl0:ngl)
  ELSE
     ! normal case: interpolation of short-range terms
     CALL  interp_vloc ( nt, ngl, gl, tpiba2, vloc )
     !
     IF ( .not. modified_coulomb ) THEN
        fac = fpi / omega * upf(nt)%zp * e2 / tpiba2
        DO igl = igl0, ngl
           !
           !   here we re-add the analytic fourier transform of erf(r)/r
           !
           vloc(igl) = vloc(igl) - fac * exp (-gl (igl)*tpiba2*0.25d0)/gl (igl)
        END DO
     END IF
  END IF
  !
  END SUBROUTINE vloc_of_g
!----------------------------------------------------------------------
SUBROUTINE dvloc_of_g( mesh, msh, rab, r, vloc_at, zp, tpiba2, ngl, gl, &
                       is_coulomb, modified_coulomb, omega, dvloc )
  !----------------------------------------------------------------------
  !! This routine computes:
  !! \[ \text{dvloc} = D\text{Vloc}(g^2)/Dg^2 = (1/2g)\ D\text{Vloc}(g)/Dg
  !! \]
  !
  INTEGER, INTENT(IN) :: ngl
  !! the number of shell of G vectors
  INTEGER, INTENT(IN) :: mesh
  !! max number of mesh points
  INTEGER, INTENT(IN) :: msh
  !! number of mesh points for radial integration
  LOGICAL, INTENT(IN) :: is_coulomb
  !! for pure Coulomb pseudopotentials
  LOGICAL, INTENT(IN) :: modified_coulomb
  !! for ESM and 2D calculations
  REAL(DP), INTENT(IN) :: zp
  !! valence pseudocharge
  REAL(DP), INTENT(IN) :: rab(mesh)
  !! the derivative of the radial grid
  REAL(DP), INTENT(IN) :: r(mesh)
  !! the radial grid
  REAL(DP), INTENT(IN) :: vloc_at(mesh)
  !! the pseudo on the radial grid 
  REAL(DP), INTENT(IN) :: tpiba2
  !! 2 pi / alat
  REAL(DP), INTENT(IN) :: omega
  !! the volume of the unit cell
  REAL(DP), INTENT(IN) :: gl(ngl)
  !! the moduli of g vectors for each s
  REAL(DP), INTENT(OUT) ::  dvloc(ngl)
  !! the Fourier transform dVloc/dG
  !
  ! ... local variables
  !
  REAL(DP) :: vlcp, g2a, gx, vlcp_0, vlcp_1
  REAL(DP), ALLOCATABLE :: aux(:,:), aux1(:)
  INTEGER :: i, igl, igl0
  ! counter on erf functions or gaussians
  ! counter on g shells vectors
  ! first shell with g != 0
  REAL(DP), PARAMETER :: r12=1.0d0/3.0d0 
  !
  !$acc data present( dvloc, gl )
  !
  ! the  G=0 component is not computed
  IF (gl(1) < eps8) THEN
     !$acc kernels
     dvloc(1) = 0.0d0
     !$acc end kernels
     igl0 = 2
  ELSE
     igl0 = 1
  ENDIF
  !
  IF ( is_coulomb ) THEN
     !$acc kernels
     dvloc(igl0:ngl) = fpi*zp*e2 / omega / (tpiba2*gl(igl0:ngl))**2
     !$acc end kernels
     RETURN
  END IF
  !
  ! Pseudopotentials in numerical form (Vloc contains the local part)
  ! In order to perform the Fourier transform, a term erf(r)/r is
  ! subtracted in real space and added again in G space
  !
  ALLOCATE( aux1(mesh) )
  !
  ! This is the part of the integrand function
  ! indipendent of |G| in real space
  !
  ALLOCATE( aux(mesh,ngl) )
  !
  !$acc data copyin(r,rab) create(aux1,aux)
  !
  !$acc parallel loop copyin(vloc_at)
  DO i = 1, msh
     aux1(i) = r(i)*vloc_at(i) + zp*e2*ERF(r(i))
  ENDDO
  !
#if defined(_OPENACC)
!$acc parallel loop gang present(aux,aux1,rab,r,dvloc)
#else
!$omp parallel private( gx, vlcp, vlcp_1, vlcp_0, g2a )
!$omp do
#endif
  DO igl = igl0, ngl
     !
     gx = SQRT(gl(igl)*tpiba2)
     !
     !    and here we perform the integral, after multiplying for the |G|
     !    dependent  part
     !
     ! DV(g)/Dg = Integral of r (Dj_0(gr)/Dg) V(r) dr
     !
     !$acc loop seq
     DO i = 1, msh
       aux(i,igl) = aux1(i)*(r(i)*COS(gx*r(i))/gx - SIN(gx*r(i))/gx**2)
     ENDDO
     !
     !----Simpson int.---
     vlcp_0 = 0.0d0    
     !$acc loop seq reduction(+:vlcp_0)
     DO i = 2, msh-1,  2
       vlcp_0 = vlcp_0 + ( aux(i-1,igl)*rab(i-1) + 4.0d0*aux(i,igl)*rab(i) + &
                           aux(i+1,igl)*rab(i+1) )*r12
     ENDDO
     !------
     vlcp_1 = vlcp_0 * fpi / omega / 2.0d0 / gx
     !
     ! DV(g^2)/Dg^2 = (DV(g)/Dg)/2g
     !vlcp = fpi / omega / 2.0d0 / gx * vlcp
     !
     ! for ESM stress
     ! In ESM, vloc and dvloc have only short term.
     IF ( .NOT. modified_coulomb ) THEN
        ! subtract the long-range term
        ! 2D cutoff: do not re-add LR part here re-added later in stres_loc)
        g2a = gl(igl) * tpiba2 / 4.d0
        vlcp = vlcp_1 + fpi / omega * zp * e2 * EXP(-g2a) * (g2a + 1.d0) / &
                          (gl(igl)*tpiba2)**2
     ELSE
        vlcp = vlcp_1
     ENDIF
     dvloc(igl) = vlcp
  ENDDO
#if !defined(_OPENACC)
!$omp end do nowait
!$omp end parallel
#else
!$acc end data
!$acc end data
#endif
  !
  DEALLOCATE( aux )
  DEALLOCATE( aux1 )
  !
  RETURN
  !
END SUBROUTINE dvloc_of_g
!
END MODULE vloc_mod
