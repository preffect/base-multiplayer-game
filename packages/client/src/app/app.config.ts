import type { ApplicationConfig } from '@angular/core';
import { provideZonelessChangeDetection } from '@angular/core';
import type { Routes } from '@angular/router';
import { provideRouter } from '@angular/router';

// TODO: Define routes for game screens (lobby, game, results, etc.)
const routes: Routes = [];

export const appConfig: ApplicationConfig = {
  providers: [provideZonelessChangeDetection(), provideRouter(routes)],
};
